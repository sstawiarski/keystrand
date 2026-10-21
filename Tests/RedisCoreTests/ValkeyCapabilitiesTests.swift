import Foundation
@testable import RedisCore
import TestSupport
import Testing

struct ValkeyCapabilitiesTests {
    static let valkey = ValkeyFixtures.capabilities
    static let redis8 = DatabaseCapabilities(
        redisVersion: "8.0.3", serverFlavor: .redis, serverVersion: "8.0.3",
        modules: [RedisModuleInfo(name: "ReJSON", version: 20_803), RedisModuleInfo(name: "search", version: 21_012),
                  RedisModuleInfo(name: "bf", version: 20_802)])
    static let redis72 = DatabaseCapabilities(redisVersion: "7.2.0", serverFlavor: .redis, serverVersion: "7.2.0")

    @Test func parsesValkeyIdentityFromInfo() {
        let info = ServerInfoParser.parse(ValkeyFixtures.serverInfo)
        #expect(info.serverName == "valkey")
        #expect(info.valkeyVersion == "9.1.2")
        #expect(info.serverFlavor == .valkey)
        #expect(info.serverVersion == "9.1.2")
        #expect(info.redisVersion == "7.2.4")

        let redis = ServerInfoParser.parse("# Server\r\nredis_version:8.0.3\r\n")
        #expect(redis.serverName == nil)
        #expect(redis.valkeyVersion == nil)
        #expect(redis.serverFlavor == .redis)
        #expect(redis.serverVersion == "8.0.3")
    }

    @Test func valkeyNineCapabilities() {
        let caps = Self.valkey
        #expect(caps.serverDisplayName == "Valkey 9.1.2")
        #expect(caps.isValkey(atLeast: "9.0.0"))
        #expect(!caps.isRedis(atLeast: "7.0.0"))
        #expect(caps.isVersion(atLeast: "7.2.0"))
        #expect(!caps.isVersion(atLeast: "7.4.0"))

        #expect(caps.hasJSON)
        #expect(caps.supportsJSONPath)
        #expect(caps.jsonMajorVersion == 1)

        #expect(caps.hasSearch)
        #expect(caps.searchFlavor == .valkeySearch)
        #expect(caps.searchVersion == 10_201)
        #expect(!caps.supportsFloat16Vectors)
        #expect(!caps.supportsSearchMatchAll)
        #expect(!caps.supportsSearchExplain)
        #expect(!caps.searchIndexesRequireDB0)

        #expect(caps.hasBloom)
        #expect(caps.missingModule(for: "CF.ADD k v") == .probabilistic)
        #expect(caps.effectiveModuleNames == ["json", CommandModuleRequirement.bloomFilterOnlyModule, "search"])

        #expect(!caps.supportsVectorSets)
        #expect(!caps.supportsVsimWithAttribs)
        #expect(!caps.supportsArray)
        #expect(caps.supportsHashFieldTTL)
        #expect(caps.supportsHashFieldKeepTTL)
        #expect(caps.supportsClusterDatabases)
    }

    @Test func redisEightCapabilities() {
        let caps = Self.redis8
        #expect(caps.serverDisplayName == "Redis 8.0.3")
        #expect(caps.isRedis(atLeast: "8.0.0"))
        #expect(!caps.isValkey(atLeast: "1.0.0"))

        #expect(caps.hasJSON)
        #expect(caps.supportsJSONPath)
        #expect(caps.jsonMajorVersion == 2)

        #expect(caps.searchFlavor == .rediSearch)
        #expect(caps.searchVersion == 21_012)
        #expect(caps.supportsFloat16Vectors)
        #expect(caps.supportsSearchMatchAll)
        #expect(caps.supportsSearchExplain)
        #expect(caps.searchIndexesRequireDB0)

        #expect(caps.missingModule(for: "CF.ADD k v") == nil)
        #expect(caps.effectiveModuleNames == ["rejson", "search", "bf"])

        #expect(caps.supportsVectorSets)
        #expect(caps.supportsVsimWithAttribs)
        #expect(!caps.supportsArray)
        #expect(caps.supportsHashFieldTTL)
        #expect(caps.supportsHashFieldKeepTTL)
        #expect(!caps.supportsClusterDatabases)
    }

    @Test func redisSevenTwoWithoutModules() {
        let caps = Self.redis72
        #expect(caps.serverDisplayName == "Redis 7.2.0")
        #expect(!caps.hasJSON)
        #expect(!caps.supportsJSONPath)
        #expect(caps.jsonMajorVersion == nil)
        #expect(!caps.hasSearch)
        #expect(caps.searchFlavor == nil)
        #expect(caps.searchVersion == nil)
        #expect(!caps.supportsFloat16Vectors)
        #expect(caps.supportsSearchMatchAll)
        #expect(caps.supportsSearchExplain)
        #expect(caps.searchIndexesRequireDB0)
        #expect(!caps.hasBloom)
        #expect(caps.missingModule(for: "CF.ADD k v") == .probabilistic)
        #expect(!caps.supportsVectorSets)
        #expect(!caps.supportsHashFieldTTL)
        #expect(!caps.supportsHashFieldKeepTTL)
        #expect(!caps.supportsClusterDatabases)
    }

    @Test func legacyCapabilitiesWithoutServerVersion() {
        let caps = DatabaseCapabilities(redisVersion: "7.4.1")
        #expect(caps.serverFlavor == .redis)
        #expect(caps.supportsHashFieldTTL)
        #expect(!caps.supportsHashFieldKeepTTL)
        #expect(caps.serverDisplayName == "Redis 7.4.1")
        let unknownValkey = DatabaseCapabilities(redisVersion: "7.2.4", serverFlavor: .valkey)
        #expect(!unknownValkey.supportsHashFieldTTL)
        #expect(unknownValkey.serverDisplayName == "Valkey")
    }

    @Test func displayNames() {
        #expect(DatabaseCapabilities.displayName(flavor: .valkey, version: "9.1.2") == "Valkey 9.1.2")
        #expect(DatabaseCapabilities.displayName(flavor: .redis, version: "8.0.3") == "Redis 8.0.3")
        #expect(DatabaseCapabilities.displayName(flavor: .redis, version: nil) == "Redis")
        #expect(DatabaseCapabilities.displayName(flavor: .valkey, version: "") == "Valkey")
        #expect(DatabaseCapabilities().serverDisplayName == "Redis")
    }

    @Test func bloomFilterTypeNames() {
        let valkeyBloom = KeyType(rawValue: "bloomfltr")
        #expect(valkeyBloom == .unknown("bloomfltr"))
        #expect(valkeyBloom.rawValue == "bloomfltr")
        #expect(valkeyBloom.displayName == "Bloom Filter")
        #expect(KeyType(typeReply: "bloomfltr")?.displayName == "Bloom Filter")
        #expect(KeyType(rawValue: "MBbloom--").displayName == "Bloom Filter")
    }

    @Test func jsonRequiresEitherJSONModule() {
        #expect(KeyType.json.isCreatable(with: Self.valkey))
        #expect(!KeyType.vectorSet.isCreatable(with: Self.valkey))
        #expect(KeyType.stream.isCreatable(with: Self.valkey))
        #expect(RedisModuleInfo(name: "json").displayName == "JSON")
        #expect(RedisModuleInfo(name: "search").displayName(on: .valkey) == "Valkey Search")
        #expect(RedisModuleInfo(name: "search").displayName == "Redis Search")
    }

    @Test func generalInfoAndOverviewCarryRealVersion() {
        let info = ServerInfoParser.parse(
            ValkeyFixtures.serverInfo + "# Keyspace\r\ndb0:keys=1,expires=0\r\n")
        let general = DatabaseInfoService.generalInfo(from: info, databases: 16)
        #expect(general.version == "9.1.2")
        #expect(general.serverFlavor == .valkey)

        let sample = DatabaseOverviewService.NodeSample(endpoint: RedisEndpoint(host: "h", port: 1), role: .primary,
                                                        info: info, dbSize: nil, ioThreads: 1)
        let overview = DatabaseOverviewService.aggregate([sample], isCluster: false, dbIndex: 0)
        #expect(overview.version == "9.1.2")
    }

    @Test func commandAvailabilityFollowsServerFlavor() throws {
        let catalog = CommandCatalog.shared
        let delifeq = try #require(catalog.spec(named: "DELIFEQ"))
        let commandlogGet = try #require(catalog.spec(named: "COMMANDLOG GET"))
        let explain = try #require(catalog.spec(named: "FT.EXPLAIN"))
        let profile = try #require(catalog.spec(named: "FT.PROFILE"))
        let redis = Self.redis8.commandAvailability
        #expect(!redis.includes(delifeq))
        #expect(!redis.includes(commandlogGet))
        #expect(redis.includes(explain))
        let valkey = Self.valkey.commandAvailability
        #expect(valkey.includes(delifeq))
        #expect(valkey.includes(commandlogGet))
        #expect(!valkey.includes(explain))
        #expect(!valkey.includes(profile))
        #expect(CommandAvailability.unrestricted.includes(delifeq))
        #expect(DatabaseCapabilities().commandAvailability.includes(delifeq))
    }
}

/// Live tests against the Valkey 9 bundle at 127.0.0.1:6392, DB 3.
@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.valkey))
struct LiveValkeyCoreTests {
    static let db = RedisTestServer.DB.redisCore

    @Test(RedisTestServer.needs(.json, .search, on: .valkey)) func connectLoadsValkeyCapabilities() async throws {
        let connection = try await RedisTestServer.freshConnection(db: Self.db, endpoint: RedisTestServer.valkey)
        await connection.close()
        let session = try await RedisTestServer.liveSession(db: Self.db, endpoint: RedisTestServer.valkey)
        #expect(session.state == .connected)
        let caps = session.capabilities
        #expect(caps.serverFlavor == .valkey)
        #expect(caps.serverVersion == "9.1.2")
        #expect(caps.redisVersion == "7.2.4")
        #expect(session.serverVersion == "9.1.2")
        #expect(caps.hasJSON)
        #expect(caps.supportsJSONPath)
        #expect(caps.searchFlavor == .valkeySearch)
        #expect(caps.searchVersion == 10_201)
        #expect(caps.supportsHashFieldTTL)
        #expect(caps.supportsHashFieldKeepTTL)
        #expect(!caps.supportsVectorSets)
        #expect(!caps.supportsFloat16Vectors)
        #expect(caps.missingModule(for: "CF.ADD k v") == .probabilistic)

        let stored = try await session.services.databaseStore.get(session.id)
        #expect(stored.version == "9.1.2")
        #expect(stored.provider == .valkey)

        await session.refreshOverview()
        #expect(session.overview?.version == "9.1.2")
        #expect(session.serverFlavor == .valkey)
        await session.close()
    }
}
