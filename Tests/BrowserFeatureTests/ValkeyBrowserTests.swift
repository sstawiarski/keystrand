import Foundation
@testable import BrowserFeature
import RedisCore
import TestSupport
import Testing

struct ValkeySampleDataTests {
    @Test func valkeyJSONModuleLoadsJSONSampleData() throws {
        let files = try SampleDataLoader.files(for: [RedisModuleInfo(name: "json", version: 10003)])
        #expect(files.contains("json"))
    }
}

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.valkey))
struct ValkeyAddKeyTests {
    @Test(RedisTestServer.needs(.json, on: .valkey)) func addKeyOffersFieldTTLAndJSONOnValkey() async throws {
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.browser, endpoint: RedisTestServer.valkey)
        defer { Task { await session.close() } }
        let model = AddKeyViewModel(session: session)
        #expect(model.supportsHashFieldTTL)
        model.type = .json
        #expect(!model.jsonModuleMissing)
    }
}
