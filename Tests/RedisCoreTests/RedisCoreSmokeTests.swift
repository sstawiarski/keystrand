import Foundation
import RedisCore
import TestSupport
import Testing

struct RedisCoreSmokeTests {
    @Test func keyTypeMapping() {
        #expect(KeyType(rawValue: "ReJSON-RL") == .json)
        #expect(KeyType(typeReply: "none") == nil)
        #expect(KeyType(rawValue: "MBbloom--") == .unknown("MBbloom--"))
        #expect(KeyType.stream.lengthLabel == "Entries")
    }

    @Test func parsesInfo() {
        let info = ServerInfoParser.parse("# Server\r\nredis_version:8.0.3\r\n\r\n# Keyspace\r\ndb0:keys=12,expires=1,avg_ttl=0\r\n")
        #expect(info.redisVersion == "8.0.3")
        #expect(info.keyspace[0]?.keys == 12)
        #expect(DatabaseCapabilities(redisVersion: "8.0.3").supportsVsimWithAttribs)
    }

    @Test func scanCursorRoundTrip() {
        let cursor = ScanCursor.cluster([RedisEndpoint(host: "10.0.0.1", port: 7000): 42])
        #expect(ScanCursor(parsing: cursor.description) == cursor)
    }

    @Test func databaseStoreKeepsSecretsOutOfJSON() async throws {
        let paths = AppPaths.temporary()
        let secrets = InMemorySecretStore()
        let store = DatabaseStore(paths: paths, secrets: secrets)
        let config = DatabaseConfig(name: "Local", port: 6390, password: "s3cret")
        try await store.create(config)
        #expect(try await store.list().first?.password == nil)
        #expect(try await store.get(config.id).password == "s3cret")
        let json = try String(contentsOf: paths.databasesFile, encoding: .utf8)
        #expect(!json.contains("s3cret"))
        try await store.delete([config.id])
        #expect(try await store.list().isEmpty)
    }

    @MainActor
    @Test func mockSessionExecutes() async throws {
        let session = RedisTestServer.mockSession(MockRedisClient(responses: ["DBSIZE": .integer(3)]))
        #expect(try await session.execute("DBSIZE") == .integer(3))
        session.navigator.navigate(.workbench(script: "PING"))
        #expect(session.navigator.section == .workbench)
        #expect(session.navigator.consume { if case .workbench = $0 { return true } else { return false } } != nil)
    }
}
