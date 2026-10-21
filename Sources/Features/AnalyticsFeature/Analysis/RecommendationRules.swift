import Foundation
import RedisCore

/// Everything the analysis-time recommendation rules need for one node. Probes that require Redis
/// (RTS, searchIndexes) are resolved by the analyzer and passed in as keys.
public struct RecommendationInput: Sendable {
    public var keys: [AnalyzedKey]
    /// Sum of DBSIZE over every scanned node.
    public var globalTotalKeys: Int
    public var isCluster: Bool
    public var info: RedisInfo?
    /// `set-max-intset-entries`, `hash-max-ziplist-entries`, `zset-max-ziplist-entries` when readable.
    public var configs: [String: Int]
    /// `FT._LIST` result; nil when the command failed or the module is missing.
    public var searchIndexes: [String]?
    /// `ACL LIST` lines; nil when the command failed.
    public var aclUsers: [String]?
    public var rtsKey: Data?
    public var searchIndexesKey: Data?

    public init(keys: [AnalyzedKey], globalTotalKeys: Int = 0, isCluster: Bool = false, info: RedisInfo? = nil,
                configs: [String: Int] = [:], searchIndexes: [String]? = nil, aclUsers: [String]? = nil,
                rtsKey: Data? = nil, searchIndexesKey: Data? = nil) {
        self.keys = keys
        self.globalTotalKeys = globalTotalKeys
        self.isCluster = isCluster
        self.info = info
        self.configs = configs
        self.searchIndexes = searchIndexes
        self.aclUsers = aclUsers
        self.rtsKey = rtsKey
        self.searchIndexesKey = searchIndexesKey
    }
}

/// Analysis-time recommendation rules (pure).
public enum RecommendationRules {
    public static let luaScriptsThreshold = 10
    public static let bigHashLength = 5_000
    public static let smallStringMemory = 200
    public static let smallStringCount = 10
    public static let totalKeysThreshold = 1_000_000
    public static let bigListLength = 1_000
    public static let bigSetLength = 1_000
    public static let connectedClientsThreshold = 100
    public static let bigStringMemory = 100_000
    public static let minimumRedisVersion = "7.3"
    public static let searchHashLength = 2
    public static let searchHashCount = 50
    public static let zsetProbeLimit = 100

    /// Rules evaluated once per database (node 1 only in a cluster).
    public static let databaseWideNames: Set<String> = [
        RecommendationName.luaScript.rawValue, RecommendationName.avoidLogicalDatabases.rawValue,
        RecommendationName.redisVersion.rawValue, RecommendationName.setPassword.rawValue,
    ]

    public static func evaluate(_ input: RecommendationInput, excluding excluded: Set<String> = []) -> [AnalysisRecommendation] {
        let rules: [(RecommendationName, (RecommendationInput) -> AnalysisRecommendation?)] = [
            (.luaScript, luaScript), (.bigHashes, bigHashes), (.useSmallerKeys, useSmallerKeys),
            (.avoidLogicalDatabases, avoidLogicalDatabases), (.combineSmallStringsToHashes, combineSmallStrings),
            (.increaseSetMaxIntsetEntries, increaseSetMaxIntsetEntries), (.hashHashtableToZiplist, hashHashtableToZiplist),
            (.compressionForList, compressionForList), (.bigStrings, bigStrings),
            (.zSetHashtableToZiplist, zSetHashtableToZiplist), (.bigSets, bigSets),
            (.bigAmountOfConnectedClients, connectedClients), (.rts, rts), (.redisVersion, redisVersion),
            (.searchIndexes, searchIndexes), (.setPassword, setPassword), (.searchHash, searchHash), (.searchJSON, searchJSON),
        ]
        return rules.compactMap { name, rule in
            excluded.contains(name.rawValue) ? nil : rule(input)
        }
    }

    static func luaScript(_ input: RecommendationInput) -> AnalysisRecommendation? {
        guard let value = input.info?.value("number_of_cached_scripts").flatMap({ Int($0) }), value > luaScriptsThreshold else { return nil }
        return AnalysisRecommendation(.luaScript)
    }

    static func bigHashes(_ input: RecommendationInput) -> AnalysisRecommendation? {
        firstKey(input.keys, .bigHashes) { $0.type == "hash" && ($0.length ?? 0) > bigHashLength }
    }

    static func useSmallerKeys(_ input: RecommendationInput) -> AnalysisRecommendation? {
        input.globalTotalKeys > totalKeysThreshold ? AnalysisRecommendation(.useSmallerKeys) : nil
    }

    static func avoidLogicalDatabases(_ input: RecommendationInput) -> AnalysisRecommendation? {
        guard !input.isCluster, let info = input.info else { return nil }
        let withKeys = info.keyspace.values.filter { $0.keys > 0 }
        return withKeys.count > 1 ? AnalysisRecommendation(.avoidLogicalDatabases) : nil
    }

    static func combineSmallStrings(_ input: RecommendationInput) -> AnalysisRecommendation? {
        let small = input.keys.filter { $0.type == "string" && ($0.memory ?? 0) < smallStringMemory }
        guard small.count >= smallStringCount, let first = small.first else { return nil }
        return AnalysisRecommendation(.combineSmallStringsToHashes, key: first.name)
    }

    static func increaseSetMaxIntsetEntries(_ input: RecommendationInput) -> AnalysisRecommendation? {
        guard let limit = input.configs["set-max-intset-entries"] else { return nil }
        return firstKey(input.keys, .increaseSetMaxIntsetEntries) { $0.type == "set" && ($0.length ?? 0) > limit }
    }

    static func hashHashtableToZiplist(_ input: RecommendationInput) -> AnalysisRecommendation? {
        guard let limit = input.configs["hash-max-ziplist-entries"] else { return nil }
        return firstKey(input.keys, .hashHashtableToZiplist) { $0.type == "hash" && ($0.length ?? 0) > limit }
    }

    static func compressionForList(_ input: RecommendationInput) -> AnalysisRecommendation? {
        firstKey(input.keys, .compressionForList) { $0.type == "list" && ($0.length ?? 0) > bigListLength }
    }

    static func bigStrings(_ input: RecommendationInput) -> AnalysisRecommendation? {
        firstKey(input.keys, .bigStrings) { $0.type == "string" && ($0.memory ?? 0) > bigStringMemory }
    }

    static func zSetHashtableToZiplist(_ input: RecommendationInput) -> AnalysisRecommendation? {
        guard let limit = input.configs["zset-max-ziplist-entries"] else { return nil }
        return firstKey(input.keys, .zSetHashtableToZiplist) { $0.type == "zset" && ($0.length ?? 0) > limit }
    }

    static func bigSets(_ input: RecommendationInput) -> AnalysisRecommendation? {
        firstKey(input.keys, .bigSets) { $0.type == "set" && ($0.length ?? 0) > bigSetLength }
    }

    static func connectedClients(_ input: RecommendationInput) -> AnalysisRecommendation? {
        guard let clients = input.info?.connectedClients, clients > connectedClientsThreshold else { return nil }
        return AnalysisRecommendation(.bigAmountOfConnectedClients)
    }

    static func rts(_ input: RecommendationInput) -> AnalysisRecommendation? {
        input.rtsKey.map { AnalysisRecommendation(.rts, key: $0) }
    }

    static func redisVersion(_ input: RecommendationInput) -> AnalysisRecommendation? {
        needsRedisUpgrade(input.info) ? AnalysisRecommendation(.redisVersion) : nil
    }

    static func searchIndexes(_ input: RecommendationInput) -> AnalysisRecommendation? {
        input.searchIndexesKey.map { AnalysisRecommendation(.searchIndexes, key: $0) }
    }

    static func setPassword(_ input: RecommendationInput) -> AnalysisRecommendation? {
        guard let users = input.aclUsers else { return nil }
        let noPass = users.contains { line in line.split(separator: " ").contains("nopass") }
        return noPass ? AnalysisRecommendation(.setPassword) : nil
    }

    static func searchHash(_ input: RecommendationInput) -> AnalysisRecommendation? {
        guard input.searchIndexes?.isEmpty ?? true else { return nil }
        let count = input.keys.filter { $0.type == "hash" && ($0.length ?? 0) > searchHashLength }.count
        return count > searchHashCount ? AnalysisRecommendation(.searchHash) : nil
    }

    static func searchJSON(_ input: RecommendationInput) -> AnalysisRecommendation? {
        guard input.searchIndexes?.isEmpty ?? true else { return nil }
        return firstKey(input.keys, .searchJSON) { $0.type == "ReJSON-RL" }
    }

    static func firstKey(_ keys: [AnalyzedKey], _ name: RecommendationName, where predicate: (AnalyzedKey) -> Bool) -> AnalysisRecommendation? {
        keys.first(where: predicate).map { AnalysisRecommendation(name, key: $0.name) }
    }

    /// Redis below `minimumRedisVersion`. Never on Valkey, whose `redis_version` is a fixed compatibility value.
    public static func needsRedisUpgrade(_ info: RedisInfo?) -> Bool {
        guard let info, info.serverFlavor == .redis, let version = info.redisVersion else { return false }
        return isVersion(version, below: minimumRedisVersion)
    }

    /// Numeric dotted comparison; unparsable versions never trigger.
    public static func isVersion(_ version: String, below minimum: String) -> Bool {
        guard let v = RedisVersion(version), let m = RedisVersion(minimum) else { return false }
        return v < m
    }

    /// ZSCAN-based time-series heuristic: first member or its score looks like a timestamp.
    public static func looksLikeTimeSeries(member: String?, score: String?) -> Bool {
        if let member, TimestampDetector.isTimestamp(member) { return true }
        if let score, TimestampDetector.isTimestamp(score) { return true }
        return false
    }

    /// Display order: searchJSON, searchIndexes, then by name; unknown names are dropped.
    public static func sortedForDisplay(_ recommendations: [AnalysisRecommendation], known: Set<String>) -> [AnalysisRecommendation] {
        func rank(_ name: String) -> Int {
            switch name {
            case RecommendationName.searchJSON.rawValue: return 0
            case RecommendationName.searchIndexes.rawValue: return 1
            default: return 2
            }
        }

        return recommendations
            .filter { known.contains($0.name) }
            .sorted { lhs, rhs in
                let a = rank(lhs.name), b = rank(rhs.name)
                return a != b ? a < b : lhs.name < rhs.name
            }
    }
}
