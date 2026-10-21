import Foundation
import RedisCore
import TestSupport
import Testing

@MainActor
private final class ResetRecorder: SessionScopedObject {
    var resets = 0
    var closes = 0

    func sessionWillClose() async { closes += 1 }
    func sessionConnectionDidReset() async { resets += 1 }
}

@MainActor
private final class CloseOnlyObject: SessionScopedObject {
    var closes = 0

    func sessionWillClose() async { closes += 1 }
}

@MainActor
private final class GatedCloser: SessionScopedObject {
    var gate: CheckedContinuation<Void, Never>?
    var closed = false

    func sessionWillClose() async {
        await withCheckedContinuation { gate = $0 }
        closed = true
    }
}

@MainActor
struct SessionResetAndImportTests {

    // MARK: - Bulk import streaming

    @Test func importerSendsLargeFilesInBatches() async throws {
        let client = MockRedisClient(responses: ["SET": .simpleString("OK")])
        let session = RedisTestServer.mockSession(client)
        let count = CommandFileImporter.batchSize * 2 + 5
        var file = ""
        file.reserveCapacity(count * 16)
        for index in 0..<count { file += "SET k\(index) v\n" }

        var events: [BulkImportSummary] = []
        for await summary in CommandFileImporter(session: session).run(Data(file.utf8)) { events.append(summary) }

        #expect(events.map(\.processed) == [CommandFileImporter.batchSize, CommandFileImporter.batchSize * 2, count, count])
        #expect(events.last?.isFinished == true)
        #expect(events.last?.succeeded == count)
        #expect(await client.batchCount == 3)
        #expect(await client.executedCommands.count == count)
    }

    @Test func importerHandlesMixedLineEndingsBlankLinesAndParseErrors() async throws {
        let client = MockRedisClient(responses: ["SET": .simpleString("OK")])
        let session = RedisTestServer.mockSession(client)
        let file = "SET a 1\r\nSET b 2\rSET c 3\n\n   \n\"unterminated\nSET d 4"
        let summary = await CommandFileImporter(session: session).importAll(Data(file.utf8))
        #expect(summary.isFinished)
        #expect(summary.succeeded == 4)
        #expect(summary.failed == 1)
        #expect(summary.processed == 5)
        #expect(await client.executedCommandStrings == ["SET a 1", "SET b 2", "SET c 3", "SET d 4"])
    }

    @Test func importerFinishesForAFileWithoutCommands() async throws {
        let client = MockRedisClient()
        let session = RedisTestServer.mockSession(client)
        let summary = await CommandFileImporter(session: session).importAll(Data("\n\n  \r\n".utf8))
        #expect(summary.isFinished)
        #expect(summary.processed == 0)
        #expect(await client.batchCount == 0)
    }

    // MARK: - Scoped objects on connection resets

    @Test func disconnectNotifiesScopedObjects() async throws {
        let session = RedisTestServer.mockSession()
        let recorder = session.scopedObject(ResetRecorder.self) { ResetRecorder() }
        _ = session.scopedObject(CloseOnlyObject.self) { CloseOnlyObject() }
        await session.disconnect()
        #expect(recorder.resets == 1)
        await session.reconnect()
        #expect(recorder.resets == 2)
        #expect(recorder.closes == 0)
        #expect(session.scopedObject(ResetRecorder.self) { ResetRecorder() } === recorder)
    }

    @Test func connectionEditNotifiesScopedObjectsButRenameDoesNot() async throws {
        let config = DatabaseConfig(name: "Mock", host: "127.0.0.1", port: 6390)
        let session = RedisTestServer.mockSession(config: config)
        let recorder = session.scopedObject(ResetRecorder.self) { ResetRecorder() }

        var renamed = config
        renamed.name = "Renamed"
        await session.apply(config: renamed)
        #expect(recorder.resets == 0)

        var moved = renamed
        moved.host = "10.0.0.2"
        await session.apply(config: moved)
        #expect(recorder.resets == 1)
    }
}

extension LiveRedisCoreTests {
    @Test func disconnectClosesDedicatedConnections() async throws {
        let session = try await freshSession()
        let connection = try await session.makeDedicatedConnection(context: .cli)
        #expect(try await connection.ping())
        await session.disconnect()
        await #expect(throws: (any Error).self) { try await connection.ping() }
        await session.close()
    }

    @Test func connectionEditClosesDedicatedConnectionsButRenameDoesNot() async throws {
        let session = try await freshSession()
        let connection = try await session.makeDedicatedConnection(context: .cli)

        var renamed = session.config
        renamed.name = "Renamed"
        await session.apply(config: renamed)
        #expect(try await connection.ping())

        var moved = renamed
        moved.db = Self.db == 15 ? 14 : 15
        await session.apply(config: moved)
        await #expect(throws: (any Error).self) { try await connection.ping() }
        await session.close()
    }

    // MARK: - Session registry

    @Test func closeAllWaitsForACloseAlreadyInProgress() async throws {
        let session = RedisTestServer.mockSession()
        let registry = try #require(session.services.sessions)
        registry.register(session)
        let closer = session.scopedObject { GatedCloser() }
        let windowClose = Task { await registry.close(session.id) }
        while closer.gate == nil { await Task.yield() }
        #expect(registry.sessions.isEmpty)
        #expect(registry.sessionsIncludingClosing.map(\.id) == [session.id])

        let quit = Task {
            await registry.closeAll()
            return closer.closed
        }
        for _ in 0..<20 { await Task.yield() }
        closer.gate?.resume()
        #expect(await quit.value)
        #expect(registry.sessionsIncludingClosing.isEmpty)
        await windowClose.value
    }
}
