import Foundation
import RedisCore
import TestSupport
import Testing
@testable import WorkbenchFeature

/// Replies to everything except `HANG`, which waits until its task is cancelled.
private actor HangingClient: RedisClient {
    private(set) var executed: [String] = []

    func execute(_ args: [RedisArgument]) async throws -> RESPValue {
        try await pipeline([args])[0]
    }

    func pipeline(_ commands: [[RedisArgument]]) async throws -> [RESPValue] {
        let names = commands.map { String(decoding: $0.first?.data ?? Data(), as: UTF8.self).uppercased() }
        executed += names
        if names.contains("HANG") { try await Task.sleep(for: .seconds(60)) }
        return names.map { _ in .simpleString("OK") }
    }

    func close() async {}
}

@MainActor
struct WorkbenchStopTests {
    @Test func stopEndsARunThatNeverReplies() async throws {
        let client = HangingClient()
        let session = DatabaseSession(config: DatabaseConfig(name: "Hang"), services: RedisTestServer.makeServices(),
                                      client: client)
        let model = WorkbenchViewModel(session: session)
        let run = Task { await model.run(script: "[pipeline=1]\nHANG\nPING") }
        for _ in 0..<200 where await client.executed.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.isRunning)
        model.stop()
        #expect(model.isStopping)
        #expect(await run.value)
        #expect(!model.isRunning)
        #expect(!model.isStopping)
        #expect(await client.executed == ["HANG"])
        #expect(model.cards.count == 1)
        #expect(model.cards.first?.execution.result?.first?.response
                == .reply(.error(WorkbenchViewModel.stoppedMessage)))

        #expect(await model.run(script: "PING"))
        #expect(await client.executed == ["HANG", "PING"])
    }

    @Test func stopWithoutARunDoesNothing() {
        let model = WorkbenchViewModel(session: RedisTestServer.mockSession())
        model.stop()
        #expect(!model.isStopping)
    }

    @Test func connectionStateCommandsAreDetected() {
        #expect(WorkbenchViewModel.changesConnectionState("MULTI"))
        #expect(WorkbenchViewModel.changesConnectionState("client reply off"))
        #expect(WorkbenchViewModel.changesConnectionState(#""WATCH" k"#))
        #expect(!WorkbenchViewModel.changesConnectionState("GET client"))
        #expect(!WorkbenchViewModel.changesConnectionState("EXEC"))
    }
}

/// A script's connection state (MULTI, CLIENT REPLY OFF) must not leak into the next run (DB 7).
@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis))
struct WorkbenchRunConnectionLiveTests {
    @Test func multiWithoutExecDoesNotQueueTheNextRun() async throws {
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.workbench)
        let model = WorkbenchViewModel(session: session)
        #expect(await model.run(script: "MULTI"))
        #expect(await model.run(script: "PING"))
        await model.cards.first?.renderText().value
        #expect(model.cards.first?.lines?.map(\.text) == ["\"PONG\""])
        await session.close()
    }

    @Test func clientReplyOffCanBeStoppedAndTheNextRunWorks() async throws {
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.workbench)
        let model = WorkbenchViewModel(session: session)
        let run = Task { await model.run(script: "CLIENT REPLY OFF") }
        for _ in 0..<200 where !model.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.isRunning)
        model.stop()
        #expect(await run.value)
        #expect(await model.run(script: "PING"))
        await model.cards.first?.renderText().value
        #expect(model.cards.first?.lines?.map(\.text) == ["\"PONG\""])
        await session.close()
    }
}
