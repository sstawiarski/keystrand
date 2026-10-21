import Foundation
@testable import KeyTypesAdvancedFeature
import RedisCore
import RedisUI
import TestSupport
import Testing

struct ValkeyBloomNoticeTests {
    @Test func valkeyBloomTypeOffersBFInfo() {
        #expect(KeyTypeNotice.inspectCommand(forType: "bloomfltr") == "BF.INFO")
        let notice = KeyTypeNotice(type: KeyType(rawValue: "bloomfltr"), keyName: "my bloom")
        #expect(notice.workbenchScript == #"BF.INFO "my bloom""#)
        #expect(!notice.isModuleNotice)
    }

    @Test func pathDialectFollowsJSONPathSupport() {
        let path = JSONPath.root.appending(key: "a").appending(index: 0)
        #expect(path.redisPath(jsonPath: true) == path.bracketed)
        #expect(path.redisPath(jsonPath: false) == path.legacy)
    }
}

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.valkey, modules: .json, .bloom))
struct ValkeyLiveKeyTypesTests {
    @Test func jsonServiceUsesJSONPathOnValkey() async throws {
        let h = try await LiveHarness.make("vjson", valkey: true)
        defer { Task { await h.cleanup() } }
        #expect(h.session.capabilities.supportsJSONPath)
        let key = h.key("doc")
        try await h.run(["JSON.SET", .data(key), "$", #"{"name":"bike","specs":{"weight":9,"tags":["a"]}}"#])
        let service = JSONKeyService(session: h.session, key: key)

        let root = try #require(try await service.describe(.root))
        #expect(root.type == .object)
        #expect(root.length == 2)
        let specs = JSONPath.root.appending(key: "specs")
        let nested = try #require(try await service.describe(specs))
        #expect(nested.type == .object)
        #expect(nested.length == 2)
        #expect(try await service.fetchValue(specs.appending(key: "weight")) == .number("9"))

        try await service.set(specs.appending(key: "weight"), json: "12")
        #expect(try await h.run(["JSON.GET", .data(key), "$.specs.weight"]).stringValue == "[12]")

        try await service.set(specs.appending(key: "color"), json: #""red""#)
        #expect(try await h.run(["JSON.GET", .data(key), "$.specs.color"]).stringValue == #"["red"]"#)

        try await service.append(specs.appending(key: "tags"), json: #""b""#)
        #expect(try await h.run(["JSON.GET", .data(key), "$.specs.tags"]).stringValue == #"[["a","b"]]"#)

        #expect(try await service.delete(JSONPath.root.appending(key: "name")) == 1)
        #expect(try await h.run(["JSON.GET", .data(key), "$.name"]).stringValue == "[]")

        let document = try await service.fetchValue(.root)
        #expect(JSONLiteral.format(document) == #"{"specs":{"weight":12,"tags":["a","b"],"color":"red"}}"#)
    }

    @Test func jsonViewLoadsLazilyOnValkey() async throws {
        let h = try await LiveHarness.make("vjsonbig", valkey: true)
        defer { Task { await h.cleanup() } }
        let key = h.key("doc")
        let members = (0..<250).map { #""k\#($0)":{"index":\#($0),"label":"value number \#($0)"}"# }
        try await h.run(["JSON.SET", .data(key), "$", .string("{" + members.joined(separator: ",") + "}")])

        let model = JSONKeyViewModel(context: h.context(key, type: .json))
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.tree.root.childCount == 250)
        let child = JSONPath.root.appending(key: "k7")
        let loaded = try #require(try await model.actions.loadChildren?(child))
        #expect(loaded.childCount == 2)

        try await model.actions.setValue?(child.appending(key: "index"), "70")
        #expect(try await h.run(["JSON.GET", .data(key), "$.k7.index"]).stringValue == "[70]")
        try await model.actions.addEntry?(child, "extra", "true")
        #expect(try await h.run(["JSON.GET", .data(key), "$.k7.extra"]).stringValue == "[true]")
        try await model.actions.delete?(child.appending(key: "label"))
        #expect(try await h.run(["JSON.GET", .data(key), "$.k7"]).stringValue == #"[{"index":70,"extra":true}]"#)
    }

    @Test func valkeyBloomKeyOpensWithBFInfo() async throws {
        let h = try await LiveHarness.make("vbloom", valkey: true)
        defer { Task { await h.cleanup() } }
        let key = h.key("bf")
        try await h.run(["BF.ADD", .data(key), "item"])

        let info = try await KeyMetadataService(session: h.session).keyInfo(key)
        #expect(info.type == .unknown("bloomfltr"))
        #expect(info.type.displayName == "Bloom Filter")
        let notice = KeyTypeNotice(type: info.type, keyName: String(decoding: key, as: UTF8.self))
        let script = try #require(notice.workbenchScript)
        #expect(script.hasPrefix("BF.INFO "))
        let reply = try await h.session.execute(["BF.INFO", .data(key)])
        #expect(reply.errorValue == nil)
    }
}
