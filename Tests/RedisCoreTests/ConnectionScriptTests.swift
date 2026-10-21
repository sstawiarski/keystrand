import Foundation
import RedisCore
import TestSupport
import Testing

private let shFactory = RedisClientFactory(scriptRunner: ConnectionScriptRunner(timeout: 10, shell: "/bin/sh"))

private func scriptLog() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("rgtest-scripts-\(UUID().uuidString).log")
}

private func lines(_ url: URL) -> [String] {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

struct ConnectionScriptTests {
    @Test func postDisconnectScriptRunsAfterAFailedConnection() async throws {
        let log = scriptLog()
        defer { try? FileManager.default.removeItem(at: log) }
        var draft = DatabaseConfig(host: RedisTestServer.host, port: RedisTestServer.port)
        draft.preConnectScript = "exit 3"
        draft.postDisconnectScript = "echo post >> '\(log.path)'"
        do {
            try await DatabaseFactory(clientFactory: shFactory).test(draft)
            Issue.record("expected the pre-connection script to fail")
        } catch {
            #expect(ConnectionError.classify(error, endpoint: draft.endpoint).title == "Pre-connection script failed")
        }

        #expect(lines(log) == ["post"])
    }
}

extension LiveRedisCoreTests {
    @Test func testConnectionRunsThePostDisconnectScriptLast() async throws {
        let log = scriptLog()
        defer { try? FileManager.default.removeItem(at: log) }
        var draft = RedisTestServer.databaseConfig(db: Self.db)
        draft.preConnectScript = "echo pre >> '\(log.path)'"
        draft.postDisconnectScript = "echo post >> '\(log.path)'"
        try await DatabaseFactory(clientFactory: shFactory).test(draft)
        let recorded = lines(log)
        #expect(recorded.first == "pre")
        #expect(recorded.last == "post")
        #expect(recorded.filter { $0 == "post" }.count == 1)
    }

    @Test func failingPostDisconnectScriptFailsTheTest() async throws {
        var draft = RedisTestServer.databaseConfig(db: Self.db)
        draft.postDisconnectScript = "echo cleanup failed; exit 5"
        do {
            try await DatabaseFactory(clientFactory: shFactory).test(draft)
            Issue.record("expected the post-disconnect script to fail")
        } catch {
            let failure = ConnectionError.classify(error, endpoint: draft.endpoint)
            #expect(failure.title == "Post-disconnect script failed")
            #expect(failure.message == "The post-disconnect script failed with exit code 5.\ncleanup failed")
        }
    }

    @Test func sessionRunsThePostDisconnectScriptOncePerDisconnect() async throws {
        try await RedisTestServer.flush(db: Self.db)
        let log = scriptLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let services = AppServices(paths: .temporary(), secrets: InMemorySecretStore(), clientFactory: shFactory)
        var config = RedisTestServer.databaseConfig(db: Self.db)
        config.postDisconnectScript = "echo first >> '\(log.path)'"
        try await services.databaseStore.create(config)
        let session = try await services.sessions.session(for: config.id)

        await session.connect()
        #expect(session.state == .connected)
        #expect(lines(log).isEmpty)
        await session.disconnect()
        #expect(lines(log) == ["first"])
        await session.close()
        #expect(lines(log) == ["first"])

        await session.connect()
        var edited = config
        edited.timeoutMs = 20_000
        edited.postDisconnectScript = "echo second >> '\(log.path)'"
        await session.apply(config: edited)
        await session.disconnect()
        #expect(lines(log) == ["first", "first"])

        await session.connect()
        await services.sessions.close(session.id)
        #expect(lines(log) == ["first", "first", "second"])
    }

    @Test func cancellingDisconnectStopsThePostDisconnectScript() async throws {
        let log = scriptLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let services = AppServices(paths: .temporary(), secrets: InMemorySecretStore(), clientFactory: shFactory)
        var config = RedisTestServer.databaseConfig(db: Self.db)
        config.postDisconnectScript = "sleep 30; echo finished >> '\(log.path)'"
        try await services.databaseStore.create(config)
        let session = try await services.sessions.session(for: config.id)
        await session.connect()
        #expect(session.state == .connected)

        let clock = ContinuousClock()
        let disconnect = Task { await session.disconnect() }
        try await Task.sleep(for: .milliseconds(300))
        let start = clock.now
        disconnect.cancel()
        await disconnect.value
        #expect(clock.now - start < .seconds(3))
        #expect(session.toasts.toasts.isEmpty)
        #expect(lines(log).isEmpty)
        await services.sessions.close(session.id)
    }
}
