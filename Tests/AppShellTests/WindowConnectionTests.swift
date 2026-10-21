@testable import AppShell
import CLIFeature
import Foundation
import RedisCore
import TestSupport
import Testing

struct WindowContentPhaseTests {
    @Test func sectionsMountOnlyWhenConnected() {
        #expect(WindowContentPhase.make(state: .connected, userDisconnected: false) == .content)
        #expect(WindowContentPhase.make(state: .connecting, userDisconnected: false) == .connecting)
        #expect(WindowContentPhase.make(state: .disconnected, userDisconnected: false) == .connecting)
        #expect(WindowContentPhase.make(state: .disconnected, userDisconnected: true) == .disconnected)
        #expect(WindowContentPhase.make(state: .failed(.timeout), userDisconnected: false) == .failed(.timeout))
    }

    @Test func bottomPanelShowsOnlyWhileConnected() {
        #expect(WindowContentPhase.content.showsBottomPanel)
        #expect(!WindowContentPhase.disconnected.showsBottomPanel)
        #expect(!WindowContentPhase.connecting.showsBottomPanel)
        #expect(!WindowContentPhase.failed(.timeout).showsBottomPanel)
    }
}

struct ConnectionFingerprintTests {
    @Test func ignoresBookkeepingAndSecrets() {
        var config = DatabaseConfig(name: "a", host: "h", port: 1, password: "one")
        let before = ConnectionFingerprint(config)
        config.lastConnection = Date()
        config.version = "8.0.0"
        config.modules = [RedisModuleInfo(name: "search")]
        config.connectionType = .standalone
        config.name = "renamed"
        config.environment = .production
        config.password = "two"
        #expect(ConnectionFingerprint(config) == before)
    }

    @Test func detectsEndpointChanges() {
        let config = DatabaseConfig(name: "a", host: "h", port: 1)
        var moved = config
        moved.port = 2
        #expect(ConnectionFingerprint(moved) != ConnectionFingerprint(config))
        var tls = config
        tls.tls.enabled = true
        #expect(ConnectionFingerprint(tls) != ConnectionFingerprint(config))
        var user = config
        user.username = "admin"
        #expect(ConnectionFingerprint(user) != ConnectionFingerprint(config))
    }
}

@MainActor
struct WindowConnectionModelTests {
    @Test func autoConnectsOnlyOnFirstAppearance() async {
        let session = RedisTestServer.mockSession()
        await session.disconnect()
        let model = WindowConnectionModel(session: session)
        #expect(model.phase == .connecting)
        #expect(await model.connectOnFirstAppearance())
        #expect(model.phase == .content)
        await model.disconnect()
        #expect(model.phase == .disconnected)
        #expect(await model.connectOnFirstAppearance() == false)
        #expect(session.state == .disconnected)
        await model.connect()
        #expect(model.phase == .content)
        #expect(!model.userDisconnected)
    }

    @Test func configChangeReconnectsUnlessDisconnected() async {
        let session = RedisTestServer.mockSession()
        let model = WindowConnectionModel(session: session)
        await model.connect()
        var edited = session.config
        edited.host = "10.0.0.1"
        await session.apply(config: edited)
        await model.configDidChange()
        #expect(session.state == .connected)

        await model.disconnect()
        edited.port = 7000
        await session.apply(config: edited)
        await model.configDidChange()
        #expect(session.state == .disconnected)
        #expect(model.phase == .disconnected)
    }

    @Test func probeSeparatesServerErrorsFromTransportFailures() async {
        let client = MockRedisClient(responses: ["PING": .simpleString("PONG")])
        let session = RedisTestServer.mockSession(client)
        #expect(await WindowConnectionModel.probe(session) == nil)
        await client.setResponse(.error(RESPError("NOPERM no permissions")), for: "PING")
        #expect(await WindowConnectionModel.probe(session) == nil)
        await client.setTransportError(.connectionClosed)
        #expect(await WindowConnectionModel.probe(session) != nil)
    }

    @Test func overviewFailureWithDeadServerMarksConnectionLost() async {
        let client = MockRedisClient(responses: ["PING": .simpleString("PONG")])
        let session = RedisTestServer.mockSession(client)
        let model = WindowConnectionModel(session: session)
        await model.connect()
        await client.setTransportError(.connectionClosed)
        await session.refreshOverview()
        #expect(session.overviewError != nil)
        await model.overviewErrorDidChange()
        #expect(model.lostConnection != nil)

        await client.setTransportError(nil)
        await model.reconnect()
        #expect(model.lostConnection == nil)
        #expect(session.state == .connected)
    }

    @Test func disconnectStopsDedicatedToolsBeforeTheSession() async {
        let session = RedisTestServer.mockSession()
        let model = WindowConnectionModel(session: session)
        var statesAtStop: [SessionState] = []
        model.stopDedicatedTools = { statesAtStop.append($0.state) }
        await model.connect()
        await model.reconnect()
        #expect(statesAtStop.isEmpty)
        await model.disconnect()
        #expect(statesAtStop == [.connected])
        #expect(model.phase == .disconnected)
    }

    @Test func defaultStopLeavesUnopenedToolsAlone() async {
        let session = RedisTestServer.mockSession()
        await WindowConnectionModel(session: session).disconnect()
        #expect(!BottomPanelModel.shared(for: session).hasOpenedCLI)
    }

    @Test(.tags(.live), RedisTestServer.live(.redis))
    func disconnectClosesTheCLIConnection() async throws {
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.cli)
        let model = WindowConnectionModel(session: session)
        await model.connect()
        session.navigator.openBottomTools = [.cli]
        BottomPanelModel.shared(for: session).sync(session.navigator)
        let cli = CLIViewModel.shared(for: session)
        await cli.openAndWait()
        #expect(cli.connectionState == .connected)
        await model.disconnect()
        #expect(cli.connectionState == .idle)
        #expect(model.phase == .disconnected)
        await session.close()
    }
}
