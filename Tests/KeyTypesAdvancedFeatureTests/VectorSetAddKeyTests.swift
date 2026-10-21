import Foundation
@testable import KeyTypesAdvancedFeature
import RedisCore
import TestSupport
import Testing

@MainActor
struct VectorSetAddKeyTests {
    private final class Added {
        var keys: [Data] = []
    }

    private func model(_ client: MockRedisClient, ttl: Int? = 60, added: Added) -> VectorSetAddKeyModel {
        let context = AddKeyFormContext(session: RedisTestServer.mockSession(client), keyName: { Data("vs".utf8) },
                                        ttl: { ttl }, onKeyAdded: { added.keys.append($0) }, onCancel: {})
        let model = VectorSetAddKeyModel(context: context)
        model.drafts = [VectorElementInput(name: "a", vector: "1 2"), VectorElementInput(name: "b", vector: "3 4")]
        return model
    }

    @Test func submitSendsOneScriptWithEveryElementAndTheTTL() async {
        let client = MockRedisClient(responses: ["EVAL": .integer(1)])
        let added = Added()
        let model = model(client, added: added)
        #expect(await model.submit())
        #expect(added.keys == [Data("vs".utf8)])
        let executed = await client.executedCommandStrings
        #expect(executed.count == 1)
        let script = executed.first ?? ""
        #expect(script.hasPrefix("EVAL "))
        #expect(script.contains(" 1 vs "))
        #expect(script.components(separatedBy: " VADD vs ").count == 3)
        #expect(script.hasSuffix(" 3 EXPIRE vs 60"))
        #expect(!executed.contains { $0.hasPrefix("EXISTS") })
    }

    @Test func existingKeyIsRefusedInline() async {
        let added = Added()
        let model = model(MockRedisClient(responses: ["EVAL": .integer(0)]), added: added)
        #expect(await model.submit() == false)
        #expect(model.errorMessage == "This key name is already in use.")
        #expect(added.keys.isEmpty)
    }

    @Test func keyCreatedWithoutTTLCountsAsAddedAndReportsTheError() async {
        let denied = "NOPERM User u has no permissions to run the 'expire' command"
        let client = MockRedisClient(responses: ["EVAL": .array([.integer(3), .bulk(denied)])])
        let added = Added()
        let model = model(client, added: added)
        #expect(await model.submit())
        #expect(added.keys == [Data("vs".utf8)])
        #expect(model.errorMessage == nil)
        let toasts = model.context.session.toasts.toasts
        #expect(toasts.map(\.title) == [KeyOperationError.createdWithoutTTLTitle])
        #expect(toasts.first?.message == KeyOperationError.createdWithoutTTL(denied).localizedDescription)
    }

    @Test func failedElementKeepsTheFormOpen() async {
        let client = MockRedisClient(responses: ["EVAL": .array([.integer(2), .bulk("ERR Vector dimension mismatch")])])
        let added = Added()
        let model = model(client, added: added)
        #expect(await model.submit() == false)
        #expect(model.errorMessage == "ERR Vector dimension mismatch")
        #expect(added.keys.isEmpty)
    }
}
