import Foundation
@testable import MonitoringFeature
import RedisCore
import TestSupport
import Testing

@MainActor
struct ProfilerViewModelTests {
    private func makeModel(_ factory: FakeMonitorFactory, config: DatabaseConfig = DatabaseConfig(name: "Mock"))
        -> (ProfilerViewModel, DatabaseSession) {
        let session = RedisTestServer.mockSession(config: config)
        session.services.settings.app.timezone = .utc
        let model = ProfilerViewModel(session: session) { try factory.connect() }
        return (model, session)
    }

    @Test func startStreamsLinesAndFormatsThem() async throws {
        let factory = FakeMonitorFactory()
        let (model, _) = makeModel(factory)
        #expect(model.phase == .idle)
        await model.start()
        #expect(model.phase == .running)
        #expect(model.entries.isEmpty)
        #expect(!model.hasReceivedLine)
        let transport = try #require(factory.latest)
        try await transport.emit(#"1700000000.5 [0 127.0.0.1:5000] "set" "key" "va\"l""#)
        #expect(await waitUntil { model.entries.count == 1 })
        let entry = try #require(model.entries.first)
        #expect(entry.timeText == "22:13:20.500")
        #expect(entry.contextText == "[0 127.0.0.1:5000]")
        #expect(entry.commandText == "\"set\"")
        #expect(entry.argumentsText == #""key" "va\"l""#)
        #expect(model.hasReceivedLine)
        #expect(model.totalLines == 1)
    }

    @Test func primaryActionFollowsThePhase() async throws {
        let factory = FakeMonitorFactory()
        let (model, _) = makeModel(factory)
        #expect(model.commands.title == "Start Profiler")
        #expect(model.primaryActionSymbol == "record.circle")
        #expect(model.isPrimaryActionEnabled)
        await model.start()
        #expect(model.commands.title == "Pause Profiler")
        #expect(model.primaryActionSymbol == "pause.circle")
        await model.pause()
        #expect(model.commands.title == "Resume Profiler")
        #expect(model.primaryActionSymbol == "play.circle")
        await model.reset()
        #expect(model.commands.title == "Start Profiler")
    }

    @Test func productionStartAsksFirst() async {
        let factory = FakeMonitorFactory()
        let (model, _) = makeModel(factory, config: DatabaseConfig(name: "Prod", environment: .production))
        model.requestStart()
        #expect(model.isConfirmingProductionStart)
        #expect(model.phase == .idle)
        #expect(factory.latest == nil)
    }

    @Test func pauseClosesConnectionsAndResumeReopens() async throws {
        let factory = FakeMonitorFactory()
        let (model, _) = makeModel(factory)
        await model.start()
        let first = try #require(factory.latest)
        await first.emit(count: 3)
        #expect(await waitUntil { model.entries.count == 3 })
        await model.pause()
        #expect(model.phase == .paused)
        #expect(await first.isClosed)
        #expect(model.pausedSummary != nil)
        let pausedRunning = model.runningTime()
        try await Task.sleep(for: .milliseconds(120))
        #expect(model.runningTime() == pausedRunning)

        await model.start()
        #expect(model.phase == .running)
        #expect(factory.made.count == 2)
        let second = try #require(factory.latest)
        await second.emit(count: 2, startingAt: 10)
        #expect(await waitUntil { model.entries.count == 5 })
        #expect(model.runningTime() >= pausedRunning)
    }

    @Test func clearKeepsRunning() async throws {
        let factory = FakeMonitorFactory()
        let (model, _) = makeModel(factory)
        await model.start()
        let transport = try #require(factory.latest)
        await transport.emit(count: 4)
        #expect(await waitUntil { model.entries.count == 4 })
        #expect(model.canClear)
        model.clear()
        #expect(model.entries.isEmpty)
        #expect(model.phase == .running)
        await transport.emit(count: 1, startingAt: 100)
        #expect(await waitUntil { model.entries.count == 1 })
    }

    @Test func keepsAtMostTenThousandLines() async throws {
        let factory = FakeMonitorFactory()
        let (model, _) = makeModel(factory)
        await model.start()
        let transport = try #require(factory.latest)
        await transport.emit(count: 12_000)
        #expect(await waitUntil(timeout: .seconds(10)) { model.totalLines == 12_000 })
        #expect(model.entries.count == ProfilerViewModel.lineLimit)
        #expect(model.isTrimmed)
        #expect(model.entries.first?.argumentsText == "\"k2000\"")
        #expect(model.entries.last?.argumentsText == "\"k11999\"")
    }

    @Test func noPermissionShowsForbiddenState() async throws {
        let factory = FakeMonitorFactory()
        let (model, _) = makeModel(factory)
        await model.start()
        let transport = try #require(factory.latest)
        await transport.emit(count: 2)
        #expect(await waitUntil { model.entries.count == 2 })
        await transport.fail(RedisClientError.server(RESPError("NOPERM this user has no permissions to run the 'monitor' command")))
        #expect(await waitUntil { model.phase == .forbidden(MonitoringError.forbiddenMessage) })
        #expect(model.entries.isEmpty)
        #expect(await transport.isClosed)
        await model.reset()
        #expect(model.phase == .idle)
    }

    @Test func serverErrorAddsRowAndPauses() async throws {
        let factory = FakeMonitorFactory()
        let (model, _) = makeModel(factory)
        await model.start()
        let transport = try #require(factory.latest)
        await transport.fail(RedisClientError.server(RESPError("ERR something odd")))
        #expect(await waitUntil { model.phase == .paused })
        #expect(model.entries.last?.isError == true)
        #expect(model.entries.last?.commandText == "ERR something odd")
        #expect(!model.isResumeLocked)
        await model.start()
        #expect(model.phase == .running)
    }

    @Test func connectionLossLocksResume() async throws {
        let factory = FakeMonitorFactory()
        let (model, _) = makeModel(factory)
        await model.start()
        let transport = try #require(factory.latest)
        await transport.fail(RedisClientError.connectionClosed)
        #expect(await waitUntil { model.phase == .paused })
        #expect(model.entries.last?.commandText == "Error: the connection dropped")
        #expect(model.isResumeLocked)
        await model.start()
        #expect(model.phase == .paused)
        #expect(factory.made.count == 1)
        await model.reset()
        #expect(model.phase == .idle)
        #expect(!model.isResumeLocked)
    }

    @Test func unexpectedCleanEndCountsAsConnectionLoss() async throws {
        let factory = FakeMonitorFactory()
        let (model, _) = makeModel(factory)
        await model.start()
        let transport = try #require(factory.latest)
        await transport.endCleanly()
        #expect(await waitUntil { model.phase == .paused })
        #expect(model.isResumeLocked)
    }

    @Test func connectFailureOnStartStaysIdleWithError() async {
        let factory = FakeMonitorFactory()
        factory.failNext = RedisClientError.connectionFailed("refused")
        let (model, session) = makeModel(factory)
        model.saveToFile = true
        await model.start()
        #expect(model.phase == .idle)
        #expect(model.startError == "Couldn't open a connection to the database.")
        #expect(model.logFileURL == nil)
        #expect(session.toasts.toasts.count == 1)
        #expect(session.toasts.toasts.first?.title == "Couldn't open a connection to the database.")
        #expect(session.toasts.toasts.first?.message?.contains("refused") == true)
    }

    @Test func connectFailureOnResumeAddsErrorRow() async throws {
        let factory = FakeMonitorFactory()
        let (model, _) = makeModel(factory)
        await model.start()
        await model.pause()
        factory.failNext = RedisClientError.timeout
        await model.start()
        #expect(model.phase == .paused)
        #expect(model.entries.last?.commandText == "Couldn't open a connection to the database.")
        #expect(!model.isResumeLocked)
    }

    @Test func saveLogWritesEveryLineAndResetDeletesIt() async throws {
        let factory = FakeMonitorFactory()
        let (model, session) = makeModel(factory, config: DatabaseConfig(name: "Log DB"))
        model.saveToFile = true
        await model.start()
        let url = try #require(model.logFileURL)
        #expect(url.deletingLastPathComponent().standardizedFileURL
            == session.services.paths.profilerLogsDirectory.standardizedFileURL)
        let transport = try #require(factory.latest)
        await transport.emit(count: 12_000)
        #expect(await waitUntil(timeout: .seconds(10)) { model.totalLines == 12_000 })
        await model.pause()
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n")
        #expect(lines.count == 12_000)
        #expect(lines.first == #"1700000000.000000 [0 127.0.0.1:5000] "get" "k0""#)
        #expect(model.suggestedDownloadName.hasPrefix("Log DB-"))

        let destination = session.services.paths.root.appendingPathComponent("download.txt")
        try model.copyLog(to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == content)

        await model.reset()
        #expect(model.logFileURL == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(model.saveToFile)
    }

    @Test func clusterNodesAreLabelled() async throws {
        let factory = FakeMonitorFactory()
        factory.nodeLabels = ["10.0.0.2:6379", "10.0.0.1:6379"]
        let (model, _) = makeModel(factory)
        await model.start()
        #expect(factory.made.count == 2)
        #expect(model.nodeLabels == ["10.0.0.1:6379", "10.0.0.2:6379"])
        try await factory.made[0].emit(#"1700000000.0 [0 1.2.3.4:1] "ping""#)
        #expect(await waitUntil { model.entries.count == 1 })
        #expect(model.entries.first?.nodeLabel == "10.0.0.2:6379")
        #expect(model.nodeColorIndex("10.0.0.2:6379") == 1)
        await model.pause()
        for transport in factory.made { #expect(await transport.isClosed) }
    }

    @Test func closeResetsAndHidesTheTab() async {
        let factory = FakeMonitorFactory()
        let (model, session) = makeModel(factory)
        session.navigator.openBottomTools = [.cli, .profiler]
        await model.start()
        await model.close()
        #expect(model.phase == .idle)
        #expect(session.navigator.openBottomTools == [.cli])
    }

    @Test func resetAndCloseAskBeforeDiscardingAnUnsavedLog() async throws {
        let factory = FakeMonitorFactory()
        let (model, session) = makeModel(factory)
        session.navigator.openBottomTools = [.profiler]
        model.saveToFile = true
        await model.start()
        let url = try #require(model.logFileURL)
        let transport = try #require(factory.latest)
        await transport.emit(count: 3)
        #expect(await waitUntil { model.totalLines == 3 })
        await model.pause()
        #expect(model.hasUnsavedLog)

        model.requestReset()
        #expect(model.pendingDiscard == .reset)
        #expect(FileManager.default.fileExists(atPath: url.path))
        model.pendingDiscard = nil

        let destination = session.services.paths.root.appendingPathComponent("saved.txt")
        try Data("older file".utf8).write(to: destination)
        try model.copyLog(to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8).split(separator: "\n").count == 3)
        #expect(!model.hasUnsavedLog)

        model.requestClose()
        #expect(await waitUntil { model.phase == .idle })
        #expect(model.pendingDiscard == nil)
        #expect(session.navigator.openBottomTools.isEmpty)
    }

    @Test func confirmingDiscardRunsThePendingClose() async throws {
        let factory = FakeMonitorFactory()
        let (model, session) = makeModel(factory)
        session.navigator.openBottomTools = [.profiler]
        model.saveToFile = true
        await model.start()
        let url = try #require(model.logFileURL)
        await (try #require(factory.latest)).emit(count: 1)
        #expect(await waitUntil { model.totalLines == 1 })
        model.requestClose()
        #expect(model.pendingDiscard == .close)
        await model.confirmDiscard()
        #expect(model.phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(session.navigator.openBottomTools.isEmpty)
    }

    @Test func sessionCloseStopsMonitor() async throws {
        let factory = FakeMonitorFactory()
        let (model, _) = makeModel(factory)
        model.saveToFile = true
        await model.start()
        let url = try #require(model.logFileURL)
        let transport = try #require(factory.latest)
        await model.sessionWillClose()
        #expect(await transport.isClosed)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@MainActor
@Suite(.serialized)
struct ProfilerLiveTests {
    @Test(.tags(.live), RedisTestServer.live(.redis))
    func monitorsCommandsFromAnotherClient() async throws {
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.monitoring)
        defer { Task { await session.close() } }
        let model = ProfilerViewModel(session: session)
        model.saveToFile = true
        await model.start()
        #expect(model.phase == .running)
        try await Task.sleep(for: .milliseconds(200))

        let key = RedisTestServer.uniquePrefix("profiler") + "key"
        let other = try await RedisTestServer.makeConnection(db: RedisTestServer.DB.monitoring)
        _ = try await other.execute(["SET", .string(key), .data(Data([0x01, 0x22]))])
        _ = try await other.execute(["DEL", .string(key)])
        await other.close()

        #expect(await waitUntil { model.entries.contains { $0.commandText.lowercased() == "\"del\"" } })
        let set = try #require(model.entries.first { $0.commandText.lowercased() == "\"set\"" && $0.argumentsText.contains(key) })
        #expect(set.contextText.hasPrefix("[\(RedisTestServer.DB.monitoring) "))
        #expect(set.argumentsText.hasSuffix(#""\x01\"""#))

        await model.pause()
        #expect(model.phase == .paused)
        let url = try #require(model.logFileURL)
        let log = try String(contentsOf: url, encoding: .utf8)
        #expect(log.contains(key))
        #expect(log.contains(#""\u0001\"""#))

        await model.reset()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
