import Foundation
@testable import AnalyticsFeature
import RedisCore
import TestSupport
import Testing

struct RecommendationRulesTests {
    func key(_ name: String, _ type: String, memory: Int? = 100, length: Int? = nil) -> AnalyzedKey {
        AnalyzedKey(name: Data(name.utf8), type: type, memory: memory, length: length, ttl: -1)
    }

    func names(_ recommendations: [AnalysisRecommendation]) -> Set<String> { Set(recommendations.map(\.name)) }

    @Test func keyBasedRules() {
        var keys = (0..<10).map { key("small:\($0)", "string", memory: 50) }
        keys += [
            key("bighash", "hash", memory: 1_000, length: 6_000),
            key("biglist", "list", memory: 1_000, length: 1_500),
            key("bigset", "set", memory: 1_000, length: 2_000),
            key("bigstring", "string", memory: 200_000, length: 200_000),
            key("doc", "ReJSON-RL", memory: 300, length: 2),
            key("zs", "zset", memory: 300, length: 200),
        ]
        let input = RecommendationInput(keys: keys, globalTotalKeys: 2_000_000,
                                        configs: ["set-max-intset-entries": 512, "hash-max-ziplist-entries": 128, "zset-max-ziplist-entries": 128],
                                        searchIndexes: [])
        let found = RecommendationRules.evaluate(input)
        let expected: Set<String> = ["combineSmallStringsToHashes", "bigHashes", "compressionForList", "bigSets", "bigStrings",
                                     "increaseSetMaxIntsetEntries", "hashHashtableToZiplist", "zSetHashtableToZiplist",
                                     "useSmallerKeys", "searchJSON"]
        #expect(names(found) == expected)
        #expect(found.first { $0.name == "bigHashes" }?.params?.keys == [Data("bighash".utf8)])
        #expect(found.first { $0.name == "combineSmallStringsToHashes" }?.params?.keys == [Data("small:0".utf8)])
    }

    @Test func searchRulesNeedNoIndexes() {
        let hashes = (0..<51).map { key("h\($0)", "hash", length: 3) }
        let json = key("doc", "ReJSON-RL")
        let withoutIndexes = RecommendationRules.evaluate(RecommendationInput(keys: hashes + [json], searchIndexes: nil))
        #expect(names(withoutIndexes).isSuperset(of: ["searchHash", "searchJSON"]))
        let withIndexes = RecommendationRules.evaluate(RecommendationInput(keys: hashes + [json], searchIndexes: ["idx"]))
        #expect(!names(withIndexes).contains("searchHash"))
        #expect(!names(withIndexes).contains("searchJSON"))
        let fewHashes = RecommendationRules.evaluate(RecommendationInput(keys: Array(hashes.prefix(50))))
        #expect(!names(fewHashes).contains("searchHash"))
    }

    @Test func serverRules() {
        let info = ServerInfoParser.parse("""
        # Server
        redis_version:6.2.14
        # Clients
        connected_clients:150
        # Memory
        number_of_cached_scripts:11
        # Keyspace
        db0:keys=3,expires=0,avg_ttl=0
        db1:keys=5,expires=0,avg_ttl=0
        """)
        let input = RecommendationInput(keys: [], info: info, aclUsers: ["user default on nopass sanitize-payload ~* &* +@all"])
        #expect(names(RecommendationRules.evaluate(input)) == ["redisVersion", "bigAmountOfConnectedClients", "luaScript",
                                                                "avoidLogicalDatabases", "setPassword"])
        var cluster = input
        cluster.isCluster = true
        #expect(!names(RecommendationRules.evaluate(cluster)).contains("avoidLogicalDatabases"))
        let excluded = RecommendationRules.evaluate(input, excluding: RecommendationRules.databaseWideNames)
        #expect(names(excluded) == ["bigAmountOfConnectedClients"])
    }

    @Test func upgradeRecommendationIsRedisOnly() {
        let redis72 = ServerInfoParser.parse("# Server\r\nredis_version:7.2.4\r\n")
        let redis8 = ServerInfoParser.parse("# Server\r\nredis_version:8.0.3\r\n")
        let valkey = ServerInfoParser.parse(
            ValkeyFixtures.serverInfo)

        func recommends(_ info: RedisInfo) -> Bool {
            names(RecommendationRules.evaluate(RecommendationInput(keys: [], info: info))).contains("redisVersion")
        }

        func tips(_ info: RedisInfo) -> Bool {
            names(LiveTipChecks.evaluate(.init(infos: [info], isCluster: false))).contains("redisVersion")
        }

        #expect(recommends(redis72))
        #expect(tips(redis72))
        #expect(!recommends(redis8))
        #expect(!tips(redis8))
        #expect(!recommends(valkey))
        #expect(!tips(valkey))
        #expect(!RecommendationRules.needsRedisUpgrade(nil))
    }

    @Test func probesFeedRules() {
        let input = RecommendationInput(keys: [], rtsKey: Data("ts".utf8), searchIndexesKey: Data("idx".utf8))
        let found = RecommendationRules.evaluate(input)
        #expect(found.first { $0.name == "RTS" }?.params?.keys == [Data("ts".utf8)])
        #expect(found.first { $0.name == "searchIndexes" }?.params?.keys == [Data("idx".utf8)])
    }

    @Test func timestampHeuristic() {
        #expect(RecommendationRules.looksLikeTimeSeries(member: "1700000000", score: "1"))
        #expect(RecommendationRules.looksLikeTimeSeries(member: "m", score: "1700000000000"))
        #expect(RecommendationRules.looksLikeTimeSeries(member: "2024-01-02T10:00:00Z", score: "5"))
        #expect(!RecommendationRules.looksLikeTimeSeries(member: "alice", score: "42"))
    }

    @Test func versionCompare() {
        #expect(RecommendationRules.isVersion("7.2.4", below: "7.3"))
        #expect(!RecommendationRules.isVersion("8.0.1", below: "7.3"))
        #expect(!RecommendationRules.isVersion("7.3.0", below: "7.3"))
        #expect(!RecommendationRules.isVersion("garbage", below: "7.3"))
    }

    @Test func displayOrder() {
        let recs = ["bigSets", "searchIndexes", "unknownTip", "avoidLogicalDatabases", "searchJSON"].map { AnalysisRecommendation(name: $0) }
        let sorted = RecommendationRules.sortedForDisplay(recs, known: RecommendationCatalog.shared.knownNames)
        #expect(sorted.map(\.name) == ["searchJSON", "searchIndexes", "avoidLogicalDatabases", "bigSets"])
    }

    @Test func liveChecks() {
        let info = ServerInfoParser.parse("redis_version:8.10.0\r\nconnected_clients:5\r\nnumber_of_cached_scripts:0\r\n# Keyspace\r\ndb0:keys=1,expires=0\r\n")
        let busy = ServerInfoParser.parse("redis_version:8.10.0\r\nconnected_clients:500\r\n")
        let found = LiveTipChecks.evaluate(.init(infos: [info, busy], isCluster: true, aclUsers: ["user default on #abc ~* +@all"]))
        #expect(found.map(\.name) == ["bigAmountOfConnectedClients"])
    }

    @Test func liveTipsMergeCreatesOnlyMissingNames() {
        var state = LiveTipsState(tips: [LiveRecommendation(name: "bigSets", read: true, hide: true)])
        let added = state.merge([AnalysisRecommendation(name: "bigSets"), AnalysisRecommendation(name: "searchJSON"),
                                 AnalysisRecommendation(name: "luaScript"), AnalysisRecommendation(name: "luaScript")])
        #expect(added)
        #expect(state.tips.map(\.name).sorted() == ["bigSets", "luaScript", "searchJSON"])
        #expect(state.tips.first { $0.name == "bigSets" }?.hide == true)
        let addedAgain = state.merge([AnalysisRecommendation(name: "bigSets")])
        #expect(!addedAgain)
    }
}

struct RecommendationCatalogTests {
    @Test func bundledCatalogMatchesRecommendationNames() {
        let catalog = RecommendationCatalog.shared
        #expect(catalog.knownNames == Set(RecommendationName.allCases.map(\.rawValue)))
        #expect(catalog["luaScript"]?.badges == [.codeChanges])
        #expect(catalog["redisVersion"]?.badges == [.upgrade])
        #expect(catalog.title(for: "redisVersion") == "Upgrade to Redis 8")
        #expect(catalog.title(for: "notATip") == "notATip")
        for item in catalog.items.values {
            #expect(!item.deprecated, "\(item.id) is deprecated")
            #expect(!item.title.isEmpty, "\(item.id) has no title")
            #expect(!item.content.isEmpty, "\(item.id) has no content")
        }
    }

    @Test func bundledContentUsesRenderedNodeTypesOnly() throws {
        let data = try #require(RecommendationCatalog.bundledData)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        let rendered: Set<String> = ["paragraph", "span", "code", "code-link", "link", "spacer", "list"]

        func types(_ value: Any?) -> [String] {
            (value as? [Any] ?? []).flatMap { raw -> [String] in
                guard let node = raw as? [String: Any], let type = node["type"] as? String else { return ["<invalid>"] }
                return [type] + (type == "list" ? (node["value"] as? [Any] ?? []).flatMap(types) : [])
            }
        }

        for (name, entry) in root {
            #expect(entry["id"] as? String == name)
            let unsupported = types(entry["content"]).filter { !rendered.contains($0) }
            #expect(unsupported.isEmpty, "\(name) uses \(unsupported)")
            let badges = entry["badges"] as? [String] ?? []
            #expect(badges.allSatisfy { RecommendationBadge(rawValue: $0) != nil }, "\(name) has unknown badges")
        }
    }

    @Test func bundledLinksArePlainHTTPS() throws {
        func links(_ nodes: [RecommendationNode]) -> [String] {
            nodes.flatMap { node -> [String] in
                switch node {
                case .link(let href, _), .codeLink(let href, _): return [href]
                case .list(let items): return items.flatMap(links)
                default: return []
                }
            }
        }

        for item in RecommendationCatalog.shared.items.values {
            let hrefs = links(item.content)
            #expect(!hrefs.isEmpty, "\(item.id) has no link")
            for href in hrefs {
                let url = try #require(URL(string: href))
                #expect(url.scheme == "https", "\(item.id): \(href)")
                #expect(url.query == nil, "\(item.id): \(href)")
                #expect(!href.contains("utm_"), "\(item.id): \(href)")
            }
        }
    }

    @Test func parsesEveryNodeType() throws {
        let json = """
        {"demo": {"id": "demo", "title": "Demo", "deprecated": true, "badges": ["upgrade", "bogus"], "content": [
          {"type": "paragraph", "value": "Para"},
          {"type": "span", "value": "Key ${0}", "parameter": ["keys"]},
          {"type": "code", "value": "CONFIG SET"},
          {"type": "code-link", "value": {"href": "https://redis.io", "name": "SCRIPT FLUSH"}},
          {"type": "link", "value": {"href": "https://redis.io/docs", "name": "docs"}},
          {"type": "spacer", "value": "l"},
          {"type": "list", "value": [[{"type": "span", "value": "one"}], [{"type": "span", "value": "two"}]]},
          {"type": "internal-link", "value": {"path": "/integrate", "name": "RDI"}},
          {"type": "mystery", "value": "raw"}
        ]}}
        """
        let catalog = try RecommendationCatalog(data: Data(json.utf8))
        let demo = try #require(catalog["demo"])
        #expect(demo.title == "Demo")
        #expect(demo.deprecated)
        #expect(demo.badges == [.upgrade])
        #expect(demo.content.count == 8)
        #expect(demo.content[0] == .paragraph("Para"))
        #expect(demo.content[3] == .codeLink(href: "https://redis.io", name: "SCRIPT FLUSH"))
        #expect(demo.content[6] == .list([[.span("one")], [.span("two")]]))
        #expect(demo.content[7] == .unknown("raw"))
        guard case .span(let text) = demo.content[1] else { Issue.record("expected span"); return }
        #expect(RecommendationCatalog.fill(text, params: RecommendationParams(keys: [Data("user:1".utf8)])) == "Key user:1")
    }

    @Test func inlineNodesGroupIntoRuns() {
        let blocks = RecommendationContentView.blocks([.span("a"), .code("b"), .link(href: "x", name: "c"), .spacer("l"),
                                                       .paragraph("p"), .span("d")])
        #expect(blocks.count == 4)
        guard case .inline(let first) = blocks[0] else { Issue.record("expected inline run"); return }
        #expect(first.count == 3)
    }
}
