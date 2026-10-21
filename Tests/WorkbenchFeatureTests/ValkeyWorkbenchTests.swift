import Foundation
import RedisCore
import TestSupport
import Testing
@testable import WorkbenchFeature

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.valkey))
struct ValkeyWorkbenchTests {
    private func labels(_ model: WorkbenchViewModel, _ text: String) -> Set<String> {
        Set(model.completions(text: text, cursor: (text as NSString).length).map { $0.label.uppercased() })
    }

    @Test(RedisTestServer.needs(.json, .bloom, on: .valkey)) func completionsOfferValkeyModulesAndHideVectorSets() async throws {
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.workbench, endpoint: RedisTestServer.valkey)
        defer { Task { await session.close() } }
        let model = WorkbenchViewModel(session: session)
        #expect(!session.capabilities.commandAvailability.includesVectorSets)
        #expect(labels(model, "JSON.G").contains("JSON.GET"))
        #expect(labels(model, "BF.A").contains("BF.ADD"))
        #expect(labels(model, "HEXP").contains("HEXPIRE"))
        #expect(labels(model, "V").isDisjoint(with: ["VADD", "VSIM", "VCARD"]))
        #expect(labels(model, "CF.").isEmpty)
        #expect(labels(model, "TS.").isEmpty)
        #expect(labels(model, "DELI").contains("DELIFEQ"))
        #expect(labels(model, "FT.").isDisjoint(with: ["FT.EXPLAIN", "FT.PROFILE"]))
    }

    @Test(RedisTestServer.needs(.json, .bloom, on: .valkey)) func moduleChecksUseValkeyModuleNames() async throws {
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.workbench, endpoint: RedisTestServer.valkey)
        defer { Task { await session.close() } }
        let capabilities = session.capabilities
        #expect(capabilities.missingModule(for: "JSON.GET k $") == nil)
        #expect(capabilities.missingModule(for: "BF.ADD k v") == nil)
        #expect(capabilities.missingModule(for: "CF.ADD k v") == .probabilistic)

        let tutorials = TutorialsViewModel(session: session)
        let fence = try #require(TutorialFence.parse(info: "redis JSON"))
        #expect(tutorials.check(code: #"JSON.SET doc $ '{"a":1}'"#, fence: fence) == .ready)
        #expect(tutorials.check(code: "TOPK.ADD k v", fence: fence) == .moduleMissing(.probabilistic))
    }
}

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis, modules: .vectorSet))
struct RedisVectorSetCompletionTests {
    @Test func redis8OffersVectorSetCommands() async throws {
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.workbench)
        defer { Task { await session.close() } }
        let model = WorkbenchViewModel(session: session)
        #expect(session.capabilities.commandAvailability.includesVectorSets)
        let items = Set(model.completions(text: "VA", cursor: 2).map { $0.label.uppercased() })
        #expect(items.contains("VADD"))
        #expect(model.completions(text: "DELI", cursor: 4).isEmpty)
    }
}
