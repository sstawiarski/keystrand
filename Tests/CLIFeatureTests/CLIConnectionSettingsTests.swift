import Foundation
@testable import CLIFeature
import RedisCore
import TestSupport
import Testing

@MainActor
struct CLIConnectionSettingsTests {
    private func makeModel(_ clients: [MockRedisClient]) -> (CLIViewModel, DatabaseSession, ConnectGate) {
        let gate = ConnectGate(holdFrom: Int.max)
        let session = RedisTestServer.mockSession(clients[0])
        let model = CLIViewModel(session: session, helper: CommandHelperContext(catalog: .shared),
                                 connector: { _ in
                                     let call = await gate.arrive()
                                     return CLISession.Link(client: clients[min(call, clients.count) - 1], db: 0)
                                 })
        return (model, session, gate)
    }

    private func waitForConnects(_ gate: ConnectGate, _ count: Int, _ model: CLIViewModel) async throws {
        for _ in 0..<200 {
            if await gate.calls >= count, model.connectionState == .connected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func reconnectsToTheEditedEndpoint() async throws {
        let first = MockRedisClient(responses: ["GET": .bulk("old")])
        let second = MockRedisClient(responses: ["GET": .bulk("new")])
        let (model, session, gate) = makeModel([first, second])
        await model.openAndWait()
        #expect(model.endpointLabel == "127.0.0.1:6379")

        var edited = session.config
        edited.port = 6391
        await session.apply(config: edited)
        try await waitForConnects(gate, 2, model)

        #expect(await gate.calls == 2)
        #expect(await first.isClosed)
        #expect(model.connectionState == .connected)
        #expect(model.endpointLabel == "127.0.0.1:6391")
        #expect(model.output.plainText.contains(CLIViewModel.settingsChangedMessage))
        #expect(model.output.plainText.contains("Pinging Redis server on 127.0.0.1:6391"))

        await model.submit("get k")
        #expect(await first.executedCommandStrings.isEmpty)
        #expect(await second.executedCommandStrings == ["get k"])
        #expect(model.output.plainText.hasSuffix("\"new\"\n"))
    }

    @Test func keepsTheConnectionForUnrelatedChanges() async throws {
        let first = MockRedisClient()
        let (model, session, gate) = makeModel([first, MockRedisClient()])
        await model.openAndWait()

        var renamed = session.config
        renamed.name = "Renamed"
        await session.apply(config: renamed)
        try await session.select(db: 3)
        try await Task.sleep(for: .milliseconds(100))

        #expect(await gate.calls == 1)
        #expect(await !first.isClosed)
        #expect(!model.output.plainText.contains(CLIViewModel.settingsChangedMessage))
    }

    @Test func closedCLIStaysClosedAfterAnEdit() async throws {
        let (model, session, gate) = makeModel([MockRedisClient()])
        var edited = session.config
        edited.host = "10.0.0.5"
        await session.apply(config: edited)
        try await Task.sleep(for: .milliseconds(100))

        #expect(await gate.calls == 0)
        #expect(model.connectionState == .idle)
        #expect(model.endpointLabel == "10.0.0.5:6379")
    }
}
