import Foundation
@testable import KeyTypesAdvancedFeature
import RedisCore
import TestSupport
import Testing

@MainActor
struct StreamConfirmationTests {
    private let key = Data("events".utf8)

    private func makeModel(_ client: MockRedisClient) async -> (StreamViewModel, DatabaseSession) {
        let session = RedisTestServer.mockSession(client, config: DatabaseConfig(name: "Mock", environment: .production))
        await session.connect()
        let context = KeyDetailsContext(session: session, key: key, type: .stream, state: KeyDetailsState(key: key))
        return (StreamViewModel(context: context), session)
    }

    private func waitForPending(_ session: DatabaseSession) async -> ConfirmationRequest? {
        for _ in 0..<200 where session.confirmations.pending == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }

        return session.confirmations.pending
    }

    private func sentXGroup(_ client: MockRedisClient) async -> Bool {
        await client.executedCommandStrings.contains { $0.uppercased().hasPrefix("XGROUP") }
    }

    @Test func addGroupAsksOnProduction() async throws {
        let client = MockRedisClient()
        let (model, session) = await makeModel(client)
        model.draftGroupName = "workers"
        model.draftGroupId = "$"
        let task = Task { await model.saveGroup() }
        let pending = try #require(await waitForPending(session))
        #expect(pending.actionID == KeyConfirmations.editStreamGroups)
        session.confirmations.resolve(confirmed: false)
        await task.value
        #expect(!(await sentXGroup(client)))
    }

    @Test func setGroupIdAsksOnProduction() async throws {
        let client = MockRedisClient()
        let (model, session) = await makeModel(client)
        let group = ConsumerGroup(name: Data("workers".utf8), consumers: 0, pending: 0, lastDeliveredId: "0-0")
        let task = Task { await model.setGroupId(group, id: "$") }
        let pending = try #require(await waitForPending(session))
        #expect(pending.actionID == KeyConfirmations.editStreamGroups)
        session.confirmations.resolve(confirmed: false)
        #expect(await task.value == false)
        #expect(!(await sentXGroup(client)))
    }
}
