import Foundation
@testable import CLIFeature
import RedisCore
import TestSupport
import Testing

@MainActor
struct CLIViewModelMockTests {
    private func makeModel(_ client: MockRedisClient, config: DatabaseConfig = DatabaseConfig(name: "Mock"),
                           maxLines: Int = CLIOutputBuffer.defaultMaxLines) -> (CLIViewModel, DatabaseSession) {
        let session = RedisTestServer.mockSession(client, config: config)
        let model = CLIViewModel(session: session, helper: CommandHelperContext(catalog: .shared),
                                 connector: { _ in CLISession.Link(client: client, db: 0) },
                                 maxOutputLines: maxLines)
        return (model, session)
    }

    @Test func startupTextAndPrompt() async {
        let (model, _) = makeModel(MockRedisClient())
        await model.openAndWait()
        let text = model.output.plainText
        #expect(text.hasPrefix(CLICommandPlanner.introPrefix + "Workbench" + CLICommandPlanner.introSuffix))
        #expect(text.contains("\n\nConnecting…\n\nPinging Redis server on 127.0.0.1:6379"))
        #expect(text.hasSuffix("\nConnected.\nReady to execute commands.\n\n"))
        #expect(model.connectionState == .connected)
        #expect(model.prompt == "> ")
        #expect(model.output.chunks.first?.segments.contains { $0.link == .workbench } == true)
    }

    @Test func runsCommandsAndEchoesThem() async {
        let client = MockRedisClient(responses: ["GET": .bulk("v"), "INCR": .integer(7)])
        let (model, session) = makeModel(client)
        await model.openAndWait()
        await model.submit("get k")
        await model.submit("3 incr c")
        let text = model.output.plainText
        #expect(text.contains("\n> get k\n\"v\"\n"))
        #expect(text.contains("\n> 3 incr c\n(integer) 7\n(integer) 7\n(integer) 7\n"))
        #expect(await client.executedCommandStrings == ["get k", "incr c", "incr c", "incr c"])
        #expect(session.services.settings.ui.cliInputHistory.prefix(2) == ["3 incr c", "get k"])
        let echo = model.output.chunks.first { $0.text == "\n> get k\n" }
        #expect(echo?.segments.contains { $0.style == .command && $0.text == "get k" } == true)
        #expect(model.output.chunks.contains { $0.segments.contains { $0.style == .reply && $0.text == "\"v\"" } })
    }

    @Test func flushWarningCancelSendsNothing() async throws {
        let client = MockRedisClient(handler: { args in
            let verb = String(decoding: args.first ?? Data(), as: UTF8.self).uppercased()
            if verb == "FLUSHDB" || verb == "FLUSHALL" { Issue.record("\(verb) reached the client") }
            return nil
        })
        let (model, _) = makeModel(client)
        await model.openAndWait()
        await client.resetRecording()
        for line in ["flushdb", #""\x46LUSHALL""#] {
            let run = Task { await model.submit(line) }
            for _ in 0..<100 where model.pendingFlush == nil {
                try await Task.sleep(for: .milliseconds(10))
            }

            let pending = try #require(model.pendingFlush)
            #expect(model.isExecuting)
            model.resolveFlush(confirmed: false)
            await run.value
            #expect(pending.message.contains(CommandWarnings.flushIndexLossWarning))
            #expect(model.output.plainText.hasSuffix("Command cancelled.\n"))
        }

        #expect(await client.executedCommands.isEmpty)
    }

    @Test func passwordsAreMaskedInSavedHistory() async {
        let client = MockRedisClient(responses: ["AUTH": .simpleString("OK")])
        let (model, session) = makeModel(client)
        await model.openAndWait()
        await model.submit("AUTH alice secret")
        #expect(await client.executedCommandStrings.last == "AUTH alice secret")
        #expect(session.services.settings.ui.cliInputHistory.first == "AUTH alice ******")
    }

    @Test func doubleEnterSubmitsOnce() async throws {
        let client = MockRedisClient(responses: ["INCR": .integer(1)])
        let (model, _) = makeModel(client)
        await model.openAndWait()
        model.setInput("incr c")
        model.submitInput()
        model.submitInput()
        #expect(model.input.isEmpty)
        for _ in 0..<100 {
            if !model.isExecuting, await !client.executedCommands.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await client.executedCommandStrings == ["incr c"])
    }

    @Test func errorsAreRed() async {
        let client = MockRedisClient(responses: ["FOO": .error(RESPError("ERR unknown command 'foo'"))])
        let (model, _) = makeModel(client)
        await model.openAndWait()
        await model.submit("foo")
        #expect(model.output.chunks.contains {
            $0.segments.contains { $0.style == .error && $0.text == "ERR unknown command 'foo'" }
        })
    }

    @Test func rejectedCommandsNeverReachRedis() async {
        let client = MockRedisClient()
        let (model, _) = makeModel(client)
        await model.openAndWait()
        await model.submit("monitor")
        await model.submit("subscribe news")
        await model.submit("psync ? -1")
        await model.submit("0 get a")
        await model.submit("set a \"b")
        let text = model.output.plainText
        #expect(text.contains(CommandRules.Guidance.monitor.message + "\n"))
        #expect(text.contains(CommandRules.Guidance.subscribe.message + "\n"))
        #expect(text.contains("psync can't be run from the CLI."))
        #expect(text.contains(CLICommandPlanner.invalidRepeatMessage + "\n"))
        #expect(text.contains("Invalid arguments: a quote is never closed.\n"))
        #expect(await client.executedCommands.isEmpty)
    }

    @Test func clearCommandAndHistoryNavigation() async {
        let (model, session) = makeModel(MockRedisClient())
        await model.openAndWait()
        await model.submit("ping")
        await model.submit("echo hi")
        await model.submit("clear")
        #expect(model.output.isEmpty)
        #expect(session.services.settings.ui.cliInputHistory.first == "clear")
        #expect(model.historyUp() == "clear")
        #expect(model.historyUp() == "echo hi")
        #expect(model.input == "echo hi")
        #expect(model.historyDown() == "clear")
        #expect(model.historyDown() == nil)
    }

    @Test func tabCompletionCyclesCommandNames() async {
        let (model, _) = makeModel(MockRedisClient())
        model.setInput("hge")
        #expect(model.complete(backwards: false) == "HGET")
        #expect(model.complete(backwards: false) == "HGETALL")
        #expect(model.complete(backwards: true) == "HGET")
        #expect(model.complete(backwards: true) == "hge")
        model.setInput("zzzz")
        #expect(model.complete(backwards: false) == nil)
    }

    @Test func inlineHintAndHelperFollowInput() async {
        let (model, _) = makeModel(MockRedisClient())
        model.setInput("set k ")
        #expect(model.hint?.hasPrefix("value") == true)
        #expect(model.helper.displayedSpec?.name == "SET")
        model.setInput("2 get ")
        #expect(model.hint == "key")
        model.setInput("")
        #expect(model.hint == nil)
    }

    @Test func lostConnectionPrintsMessageAndReconnects() async {
        let client = MockRedisClient()
        let (model, _) = makeModel(client)
        await model.openAndWait()
        await client.setTransportError(.connectionClosed)
        await model.submit("get k")
        await client.setTransportError(nil)
        let text = model.output.plainText
        #expect(text.contains("\n> get k\n" + CLICommandPlanner.connectionClosedMessage + "\n"))
        #expect(text.hasSuffix("\nConnected.\nReady to execute commands.\n\n"))
        #expect(model.connectionState == .connected)
    }

    @Test func failedConnectionShowsError() async {
        let session = RedisTestServer.mockSession()
        let model = CLIViewModel(session: session, helper: CommandHelperContext(catalog: .shared),
                                 connector: { _ in throw RedisClientError.connectionFailed("refused") })
        await model.openAndWait()
        guard case .failed(let message) = model.connectionState else {
            Issue.record("expected failure")
            return
        }
        #expect(model.output.chunks.last?.segments.first?.style == .error)
        #expect(model.output.plainText.contains(message))
        #expect(!model.canType)
    }

    @Test func productionDangerousCommandCanBeCancelled() async throws {
        let client = MockRedisClient()
        let (model, session) = makeModel(client, config: DatabaseConfig(name: "Prod", environment: .production))
        await model.openAndWait()
        let run = Task { await model.submit("keys *") }
        for _ in 0..<100 where session.confirmations.pending == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let pending = try #require(session.confirmations.pending)
        #expect(pending.title == "Production Database: Check Before Running")
        #expect(pending.message?.hasPrefix("keys * is flagged as a dangerous command. Running it on Prod") == true)
        #expect(pending.confirmButtonTitle == "Run Command")
        session.confirmations.resolve(confirmed: false)
        await run.value
        #expect(model.output.plainText.hasSuffix("\n> keys *\nCommand cancelled.\n"))
        #expect(await client.executedCommands.isEmpty)
    }

    @Test func productionSubcommandInThePipeFormServerListAsksFirst() async throws {
        let client = MockRedisClient(handler: { args in
            switch String(decoding: args.first ?? Data(), as: UTF8.self).uppercased() {
            case "INFO": return .bulk("# Server\r\nredis_version:8.0.0\r\n")
            case "ACL": return .array(["config|set", "config|get", "acl|setuser", "client|kill"].map { .bulk($0) })
            default: return nil
            }
        })
        let (model, session) = makeModel(client, config: DatabaseConfig(name: "Prod", environment: .production))
        await session.connect()
        try await session.refreshInfo()
        #expect(session.dangerousCommands.contains("config|set"))
        await model.openAndWait()
        await client.resetRecording()
        let run = Task { await model.submit("CONFIG SET maxmemory 1") }
        for _ in 0..<100 where session.confirmations.pending == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let pending = try #require(session.confirmations.pending)
        #expect(pending.actionID == "redis-command:CONFIG")
        #expect(pending.message?.hasPrefix("CONFIG SET maxmemory 1 is flagged as a dangerous command. Running it on Prod") == true)
        session.confirmations.resolve(confirmed: false)
        await run.value
        #expect(model.output.plainText.hasSuffix("\n> CONFIG SET maxmemory 1\nCommand cancelled.\n"))
        #expect(await client.executedCommands.isEmpty)
    }

    @Test func outputLineLimitIsEnforced() async {
        let client = MockRedisClient(responses: ["PING": .simpleString("PONG")])
        let (model, _) = makeModel(client, maxLines: 50)
        await model.openAndWait()
        await model.submit("100 ping")
        #expect(model.output.lineCount <= 50)
        #expect(model.output.plainText.hasSuffix("\"PONG\"\n"))
    }

    @Test func closeKeepsOutputAndReopenAppendsConnectionLines() async {
        let client = MockRedisClient()
        let (model, _) = makeModel(client)
        await model.openAndWait()
        await model.submit("ping")
        await model.closeCLI()
        #expect(model.connectionState == .idle)
        #expect(await client.isClosed)
        await model.openAndWait()
        let text = model.output.plainText
        #expect(text.components(separatedBy: CLICommandPlanner.introPrefix).count == 2)
        #expect(text.components(separatedBy: "Ready to execute commands.").count == 3)
    }

    @Test func flushAsksEvenWhenModulesAreUnknown() async throws {
        let client = MockRedisClient()
        let (model, session) = makeModel(client)
        #expect(session.modules.isEmpty)
        await model.openAndWait()
        let run = Task { await model.submit("flushdb") }
        for _ in 0..<100 where model.pendingFlush == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let pending = try #require(model.pendingFlush)
        #expect(pending.verb == "FLUSHDB")
        #expect(pending.message.contains(CommandWarnings.flushIndexLossWarning))
        model.dismissFlush(pending.id)
        await run.value
        #expect(model.output.plainText.hasSuffix("\n> flushdb\nCommand cancelled.\n"))
        #expect(await client.executedCommands.isEmpty)
    }

    @Test func confirmedFlushIgnoresTheLaterDismissal() async throws {
        let client = MockRedisClient(responses: ["FLUSHALL": .simpleString("OK")])
        let (model, _) = makeModel(client)
        await model.openAndWait()
        let run = Task { await model.submit("flushall") }
        for _ in 0..<100 where model.pendingFlush == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let pending = try #require(model.pendingFlush)
        model.resolveFlush(confirmed: true)
        model.dismissFlush(pending.id)
        await run.value
        #expect(await client.executedCommandStrings == ["flushall"])
        #expect(model.output.plainText.hasSuffix("\"OK\"\n"))
    }

    @Test func closingDuringReconnectStaysClosed() async throws {
        let first = MockRedisClient()
        let second = MockRedisClient()
        let gate = ConnectGate(holdFrom: 2)
        let session = RedisTestServer.mockSession(first)
        let model = CLIViewModel(session: session, helper: CommandHelperContext(catalog: .shared),
                                 connector: { _ in
                                     let call = await gate.arrive()
                                     return CLISession.Link(client: call == 1 ? first : second, db: 0)
                                 })
        await model.openAndWait()
        await first.setTransportError(.connectionClosed)
        let run = Task { await model.submit("get k") }
        try await gate.waitUntilHolding()
        #expect(model.connectionState == .connecting)
        await model.closeCLI()
        await gate.release()
        await run.value
        #expect(model.connectionState == .idle)
        #expect(await second.isClosed)
        #expect(!model.output.plainText.hasSuffix("\nConnected.\nReady to execute commands.\n\n"))
        #expect(model.output.plainText.hasSuffix(CLICommandPlanner.connectionClosedMessage + "\n"))
    }

    @Test func linksNavigate() {
        let (model, session) = makeModel(MockRedisClient())
        session.navigator.openBottomTools = [.cli]
        model.open(.profiler)
        #expect(session.navigator.openBottomTools.contains(.profiler))
        model.open(.workbench)
        #expect(!session.navigator.openBottomTools.contains(.cli))
        #expect(session.navigator.section == .workbench)
        model.open(.pubSub)
        #expect(session.navigator.section == .pubSub)
    }
}

@MainActor
@Suite(.serialized)
struct CLIViewModelLiveTests {
    private let db = RedisTestServer.DB.cli

    @Test(.tags(.live), RedisTestServer.live(.redis)) func runsAgainstLiveServer() async throws {
        let connection = try await RedisTestServer.freshConnection(db: db)
        defer { Task { await connection.close() } }
        let session = try await RedisTestServer.liveSession(db: db)
        let model = CLIViewModel(session: session)
        await model.openAndWait()
        #expect(model.connectionState == .connected)
        #expect(model.prompt == "[db8] > ")
        #expect(model.output.plainText.contains("Pinging Redis server on 127.0.0.1:6390[db8]"))

        await model.submit("set \"cli:bin\\xff\" \"v\\x00w\"")
        await model.submit("get \"cli:bin\\xff\"")
        await model.submit("strlen \"cli:bin\\xff\"")
        let text = model.output.plainText
        #expect(text.contains("\"OK\"\n"))
        #expect(text.contains("\"v\\x00w\"\n"))
        #expect(text.contains("(integer) 3\n"))
        let stored = try await connection.execute(["GET", .data(Data("cli:bin".utf8) + Data([0xFF]))])
        #expect(stored.dataValue == Data([0x76, 0x00, 0x77]))

        await model.submit("rpush cli:list a b")
        await model.submit("lrange cli:list 0 -1")
        #expect(model.output.plainText.hasSuffix("1) \"a\"\n2) \"b\"\n"))

        await model.submit("nosuchcommand")
        #expect(model.output.chunks.last?.segments.first?.style == .error)
        await model.sessionWillClose()
        await session.close()
    }

    @Test(.tags(.live), RedisTestServer.live(.redis)) func selectChangesPromptAndIsIndependent() async throws {
        let connection = try await RedisTestServer.freshConnection(db: db)
        defer { Task { await connection.close() } }
        let session = try await RedisTestServer.liveSession(db: db)
        let model = CLIViewModel(session: session)
        await model.openAndWait()
        await model.submit("select 9")
        #expect(model.prompt == "[db9] > ")
        #expect(session.dbIndex == db)
        await model.submit("select nope")
        #expect(model.prompt == "[db9] > ")
        await model.submit("select 0")
        #expect(model.prompt == "> ")
        await model.submit("select 8")
        await model.submit("set cli:here 1")
        #expect(try await connection.execute(["EXISTS", "cli:here"]).intValue == 1)

        await model.reconnect()
        #expect(model.prompt == "[db8] > ")
        await model.submit("exists cli:here")
        #expect(model.output.plainText.hasSuffix("(integer) 1\n"))
        await model.sessionWillClose()
        await session.close()
    }

    @Test(.tags(.live), RedisTestServer.live(.redis)) func repeatAndLargeCollection() async throws {
        let connection = try await RedisTestServer.freshConnection(db: db)
        defer { Task { await connection.close() } }
        let members = (0..<10_000).map { RedisArgument.string("m\($0)") }
        _ = try await connection.execute(["RPUSH", "cli:big"] + members)
        let session = try await RedisTestServer.liveSession(db: db)
        let model = CLIViewModel(session: session)
        await model.openAndWait()
        await model.submit("3 incr cli:counter")
        #expect(model.output.plainText.hasSuffix("(integer) 1\n(integer) 2\n(integer) 3\n"))

        let start = ContinuousClock.now
        await model.submit("lrange cli:big 0 -1")
        #expect(ContinuousClock.now - start < .seconds(5))
        let last = model.output.chunks.last?.text ?? ""
        #expect(last.hasPrefix("1) \"m0\"\n"))
        #expect(last.hasSuffix("10000) \"m9999\"\n"))
        await model.sessionWillClose()
        await session.close()
    }

    @Test(.tags(.live), RedisTestServer.live(.redis)) func blockingCommandCanBeCancelled() async throws {
        let connection = try await RedisTestServer.freshConnection(db: db)
        defer { Task { await connection.close() } }
        let session = try await RedisTestServer.liveSession(db: db)
        let model = CLIViewModel(session: session)
        await model.openAndWait()
        let run = Task { await model.submit("blpop cli:nothing 0") }
        for _ in 0..<100 where !model.isExecuting {
            try await Task.sleep(for: .milliseconds(10))
        }

        try await Task.sleep(for: .milliseconds(100))
        model.cancelExecution()
        await run.value
        #expect(!model.isExecuting)
        #expect(model.output.plainText.hasSuffix("Command cancelled.\n"))
        await model.submit("ping")
        #expect(model.output.plainText.hasSuffix("\"PONG\"\n"))
        await model.sessionWillClose()
        await session.close()
    }

    @Test(.tags(.live), RedisTestServer.live(.redis)) func scopedObjectsAreShared() async throws {
        let session = try await RedisTestServer.liveSession(db: db)
        let model = CLIViewModel.shared(for: session)
        #expect(CLIViewModel.shared(for: session) === model)
        #expect(session.scopedObject(CommandHelperContext.self) { CommandHelperContext() } === model.helper)
        await model.openAndWait()
        await session.close()
        #expect(model.connectionState == .idle)
    }
}
