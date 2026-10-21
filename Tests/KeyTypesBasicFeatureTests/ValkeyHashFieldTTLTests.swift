import Foundation
@testable import KeyTypesBasicFeature
import RedisCore
import TestSupport
import Testing

struct ValkeyFieldTTLStrategyTests {
    @Test func strategyFollowsServerFlavor() {
        let valkey9 = DatabaseCapabilities(redisVersion: "7.2.4", serverFlavor: .valkey, serverVersion: "9.1.2")
        let valkey8 = DatabaseCapabilities(redisVersion: "7.2.4", serverFlavor: .valkey, serverVersion: "8.1.0")
        let redis8 = DatabaseCapabilities(redisVersion: "8.0.3", serverVersion: "8.0.3")
        let redis74 = DatabaseCapabilities(redisVersion: "7.4.2", serverVersion: "7.4.2")
        let redis72 = DatabaseCapabilities(redisVersion: "7.2.4", serverVersion: "7.2.4")
        #expect(HashService.FieldTTLStrategy.for(valkey9) == .keepTTL)
        #expect(HashService.FieldTTLStrategy.for(valkey8) == .plain)
        #expect(HashService.FieldTTLStrategy.for(redis8) == .keepTTL)
        #expect(HashService.FieldTTLStrategy.for(redis74) == .restoreExpireTime)
        #expect(HashService.FieldTTLStrategy.for(redis72) == .plain)
    }
}

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.valkey))
struct ValkeyLiveHashFieldTTLTests {
    private func fieldTTL(_ h: LiveHarness, _ key: Data, _ field: String) async throws -> Int {
        Int(try await h.run(["HTTL", .data(key), "FIELDS", "1", .string(field)]).arrayValue?.first?.intValue ?? -9)
    }

    @Test func hashValueEditKeepsFieldTTLOnValkey() async throws {
        let h = try await LiveHarness.make("vhkeep", valkey: true)
        defer { Task { await h.cleanup() } }
        #expect(HashService.FieldTTLStrategy.for(h.session.capabilities) == .keepTTL)
        let key = h.key("h")
        try await h.run(["HSET", .data(key), "f", "v", "g", "w"])
        try await h.run(["HEXPIRE", .data(key), "1000", "FIELDS", "1", "f"])
        let model = HashKeyViewModel(context: h.context(key, type: .hash))
        await model.load()
        #expect(model.supportsFieldTTL)
        #expect((model.rows.first { $0.field == Data("f".utf8) }?.expire ?? 0) > 990)

        model.beginEdit(Data("f".utf8))
        model.editDraft = "v2"
        #expect(await model.saveEdit())
        #expect(try await h.run(["HGET", .data(key), "f"]).stringValue == "v2")
        #expect(try await fieldTTL(h, key, "f") > 990)

        model.beginEdit(Data("g".utf8))
        model.editDraft = "w2"
        #expect(await model.saveEdit())
        #expect(try await fieldTTL(h, key, "g") == -1)
    }

    @Test func hashAddAndTTLEditsOnValkey() async throws {
        let h = try await LiveHarness.make("vhadd", valkey: true)
        defer { Task { await h.cleanup() } }
        let key = h.key("h")
        try await h.run(["HSET", .data(key), "f", "v"])
        try await h.run(["HEXPIRE", .data(key), "1000", "FIELDS", "1", "f"])
        let model = HashKeyViewModel(context: h.context(key, type: .hash))
        await model.load()

        model.openAddPanel()
        model.addRows = [.init(field: "f", value: "new"), .init(field: "e", value: "y", ttl: "50")]
        #expect(await model.submitAdd())
        #expect(try await fieldTTL(h, key, "f") > 990)
        let typed = try await fieldTTL(h, key, "e")
        #expect(typed > 0 && typed <= 50)

        model.beginTTLEdit(Data("f".utf8))
        model.ttlDraft = ""
        #expect(await model.saveTTL())
        #expect(try await fieldTTL(h, key, "f") == -1)
    }
}
