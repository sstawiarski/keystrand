import Foundation
@testable import RedisCore
import TestSupport
import Testing

/// Answers every command, but the second pipeline waits until its task is cancelled.
private actor SecondBatchHangsClient: RedisClient {
    private(set) var batches = 0

    func execute(_ args: [RedisArgument]) async throws -> RESPValue {
        try await pipeline([args])[0]
    }

    func pipeline(_ commands: [[RedisArgument]]) async throws -> [RESPValue] {
        batches += 1
        if batches == 2 { try await Task.sleep(for: .seconds(60)) }
        return commands.map { _ in .simpleString("OK") }
    }

    func close() async {}
}

@MainActor
struct CommandExecutorRunTests {
    @Test func cancellingStopsBeforeTheNextChunkAndKeepsFinishedResults() async throws {
        let client = SecondBatchHangsClient()
        let services = RedisTestServer.makeServices()
        let session = DatabaseSession(config: DatabaseConfig(name: "Hang"), services: services, client: client)
        let executor = CommandExecutor(session: session, history: services.commandHistoryStore)
        var chunks = 0
        let run = Task {
            try await executor.run(["SET a 1", "SET b 2", "SET c 3"], params: ExecuteParams(batchSize: 1),
                                   settings: AppSettings(), onChunk: { _ in chunks += 1 })
        }
        for _ in 0..<200 where await client.batches < 2 { try await Task.sleep(for: .milliseconds(10)) }
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }

        #expect(chunks == 1)
        #expect(await client.batches == 2)
        let history = await services.commandHistoryStore.list(databaseID: session.id, type: .workbench)
        #expect(history.map(\.command) == ["SET a 1"])
    }

    @Test func transportFailureIsReported() async throws {
        let client = MockRedisClient()
        await client.setTransportError(.connectionClosed)
        let session = RedisTestServer.mockSession(client)
        let executor = CommandExecutor(session: session, history: session.services.commandHistoryStore)
        var failures = 0
        _ = try await executor.run(["GET a", "GET b"], params: ExecuteParams(batchSize: 1), settings: AppSettings(),
                                   onTransportFailure: { failures += 1 })
        #expect(failures == 1)
    }

    @Test func historyIsWrittenOnceWhenTheRunEnds() async throws {
        let client = MockRedisClient(responses: ["GET": .bulk("v")])
        let session = RedisTestServer.mockSession(client)
        let paths = session.services.paths
        let file = paths.commandHistoryFile(for: session.id, type: .workbench)
        let executor = CommandExecutor(session: session, history: session.services.commandHistoryStore)
        var existedDuringRun = false
        let results = try await executor.run(["GET a", "GET b", "GET c"], params: ExecuteParams(batchSize: 1),
                                             settings: AppSettings(), onChunk: { _ in
            if FileManager.default.fileExists(atPath: file.path) { existedDuringRun = true }
        })
        #expect(results.count == 3)
        #expect(!existedDuringRun)
        let data = try Data(contentsOf: file)
        #expect(!data.contains(UInt8(ascii: "\n")))
        let reloaded = await CommandHistoryStore(paths: paths).list(databaseID: session.id, type: .workbench)
        #expect(reloaded.map(\.command) == ["GET c", "GET b", "GET a"])
    }

    @Test func repeatCountAboveTheLimitIsAnInlineError() async throws {
        let client = MockRedisClient()
        let session = RedisTestServer.mockSession(client)
        let commands = try WorkbenchScriptParser.parse("200000 GET a\n2 GET b")
        #expect(commands == ["200000 GET a", "GET b", "GET b"])
        let executor = CommandExecutor(session: session, history: session.services.commandHistoryStore)
        let results = try await executor.run(commands, params: ExecuteParams(batchSize: 10), settings: AppSettings())
        #expect(results[0].result?.first?.response
                == .reply(.error("The repeat count cannot be larger than 100,000.")))
        #expect(await client.executedCommandStrings == ["GET b", "GET b"])
    }
}

struct WorkbenchScriptParserExpansionTests {
    @Test func commentsAreRemovedBeforeRepeatExpansion() throws {
        #expect(try WorkbenchScriptParser.parse("3 INCR c // count") == ["INCR c", "INCR c", "INCR c"])
        #expect(try WorkbenchScriptParser.parse("5 // only a comment\nPING") == ["PING"])
        #expect(try WorkbenchScriptParser.parse("100000 PING").count == 100_000)
        #expect(WorkbenchScriptParser.invalidRepeatMessage("0 PING") == "The repeat count before the command isn't valid.")
        #expect(WorkbenchScriptParser.invalidRepeatMessage("100001 PING")
                == "The repeat count cannot be larger than 100,000.")
        #expect(WorkbenchScriptParser.invalidRepeatMessage("10 PING") == nil)
    }
}

struct CommandHistoryStoreFormatTests {
    @Test func prettyPrintedFilesStillLoad() async throws {
        let paths = AppPaths.temporary()
        let id = DatabaseID()
        let old = CommandExecution(databaseId: id, command: "PING", mode: .ascii,
                                   result: [CommandExecutionResult(status: .success, response: .reply(.string("PONG")))])
        try JSONFile.save([old], to: paths.commandHistoryFile(for: id, type: .workbench))
        let store = CommandHistoryStore(paths: paths)
        #expect(await store.get(old.id, databaseID: id, type: .workbench)?.result == old.result)
        try await store.add([CommandExecution(databaseId: id, command: "GET a", mode: .ascii)])
        let reloaded = await CommandHistoryStore(paths: paths).list(databaseID: id, type: .workbench)
        #expect(reloaded.map(\.command) == ["GET a", "PING"])
    }

    @Test func stagedItemsWaitForFlush() async throws {
        let paths = AppPaths.temporary()
        let id = DatabaseID()
        let store = CommandHistoryStore(paths: paths)
        await store.stage([CommandExecution(databaseId: id, command: "GET a", mode: .ascii)])
        #expect(await store.list(databaseID: id, type: .workbench).count == 1)
        #expect(!FileManager.default.fileExists(atPath: paths.commandHistoryFile(for: id, type: .workbench).path))
        try await store.flush()
        #expect(await CommandHistoryStore(paths: paths).list(databaseID: id, type: .workbench).count == 1)
    }

    @Test func passwordsAreMaskedBeforeSaving() async throws {
        let paths = AppPaths.temporary()
        let id = DatabaseID()
        let store = CommandHistoryStore(paths: paths)
        let group = CommandExecution(
            databaseId: id, command: "AUTH secret1\r\nPING", mode: .ascii, resultsMode: .group,
            result: [CommandExecutionResult(status: .success, response: .group([
                GroupItemResult(command: "AUTH secret1", response: .string("OK"), status: .success),
            ]))])
        let returned = try await store.add([
            CommandExecution(databaseId: id, command: "CONFIG SET requirepass secret2", mode: .ascii), group,
        ])
        #expect(returned.map(\.command) == ["CONFIG SET requirepass secret2", "AUTH secret1\r\nPING"])
        let text = try String(contentsOf: paths.commandHistoryFile(for: id, type: .workbench), encoding: .utf8)
        #expect(!text.contains("secret1"))
        #expect(!text.contains("secret2"))
        let listed = await store.list(databaseID: id, type: .workbench)
        #expect(listed.map(\.command) == ["CONFIG SET requirepass ******", "AUTH ******\r\nPING"])
    }
}
