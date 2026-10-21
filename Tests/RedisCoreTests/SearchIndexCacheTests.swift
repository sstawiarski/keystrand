import Foundation
@testable import RedisCore
import TestSupport
import Testing

@MainActor
struct SearchIndexCacheTests {
    private nonisolated static func info(prefix: String) -> RESPValue {
        .array([.bulk("index_name"), .bulk("idx"),
                .bulk("index_definition"), .array([.bulk("key_type"), .bulk("HASH"),
                                                   .bulk("prefixes"), .array([.bulk(prefix)])])])
    }

    private func makeSession() async throws -> (DatabaseSession, MockRedisClient) {
        let client = MockRedisClient(handler: { args in
            switch String(decoding: args.first ?? Data(), as: UTF8.self).uppercased() {
            case "INFO": return .bulk("# Server\r\nredis_version:8.0.0\r\n")
            case "MODULE": return .array([.array([.bulk("name"), .bulk("search"), .bulk("ver"), .integer(80_000)])])
            case "FT._LIST": return .array([.bulk("users"), .bulk("orders")])
            case "FT.INFO":
                let name = String(decoding: args[1], as: UTF8.self)
                return Self.info(prefix: name == "users" ? "user:" : "order:")
            default: return nil
            }
        })
        let session = RedisTestServer.mockSession(client)
        await session.connect()
        try await session.refreshInfo()
        return (session, client)
    }

    private func infoCount(_ client: MockRedisClient) async -> Int {
        await client.executedCommandStrings.filter { $0.uppercased().hasPrefix("FT.INFO") }.count
    }

    @Test func coveringIndexesReuseCachedDefinitions() async throws {
        let (session, client) = try await makeSession()
        let service = SearchIndexService(session: session)

        let first = try await service.indexes(coveringKey: Data("user:1".utf8), type: .hash)
        #expect(first.map(\.name) == [Data("users".utf8)])
        #expect(await infoCount(client) == 2)

        let second = try await service.indexes(coveringKey: Data("order:9".utf8), type: .hash)
        #expect(second.map(\.name) == [Data("orders".utf8)])
        #expect(await infoCount(client) == 2)

        service.invalidateSummaries()
        _ = try await service.indexes(coveringKey: Data("user:1".utf8), type: .hash)
        #expect(await infoCount(client) == 4)
    }
}
