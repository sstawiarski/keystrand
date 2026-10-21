import Foundation
@testable import AnalyticsFeature
import RedisCore
import TestSupport
import Testing

@MainActor
struct SlowLogConfirmationTests {
    private func makeModel(_ environment: DatabaseEnvironment, client: MockRedisClient) async -> SlowLogViewModel {
        let session = RedisTestServer.mockSession(client, config: DatabaseConfig(name: "Mock", environment: environment))
        await session.connect()
        return SlowLogViewModel(session: session)
    }

    private func waitForPending(_ session: DatabaseSession) async -> ConfirmationRequest? {
        for _ in 0..<200 where session.confirmations.pending == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }

        return session.confirmations.pending
    }

    @Test func clearAsksOnceOnEveryEnvironment() async {
        let client = MockRedisClient()
        #expect(!(await makeModel(.production, client: client)).clearNeedsDialog)
        #expect((await makeModel(.unspecified, client: client)).clearNeedsDialog)
        #expect((await makeModel(.development, client: client)).clearNeedsDialog)
    }

    @Test func configSetAsksOnProduction() async throws {
        let client = MockRedisClient(responses: ["CONFIG": .simpleString("OK")])
        let model = await makeModel(.production, client: client)
        let form = SlowLogConfigForm(slowerThan: "10", unit: .milliseconds, maxLen: "128")
        let task = Task { await model.saveConfig(form) }
        let pending = try #require(await waitForPending(model.session))
        #expect(pending.actionID == "slowlog-config")
        model.session.confirmations.resolve(confirmed: false)
        #expect(await task.value == false)
        #expect(!(await client.executedCommandStrings.contains { $0.uppercased().hasPrefix("CONFIG SET") }))
    }
}
