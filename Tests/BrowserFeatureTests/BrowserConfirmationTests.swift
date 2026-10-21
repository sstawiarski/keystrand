import Foundation
@testable import BrowserFeature
import RedisCore
import TestSupport
import Testing

@MainActor
struct BrowserConfirmationTests {
    private let key = Data("user:1".utf8)

    private func makeModel(_ environment: DatabaseEnvironment,
                           client: MockRedisClient) async -> BrowserViewModel {
        let session = RedisTestServer.mockSession(client, config: DatabaseConfig(name: "Mock", environment: environment))
        await session.connect()
        return BrowserViewModel(session: session)
    }

    private func waitForPending(_ session: DatabaseSession) async -> ConfirmationRequest? {
        for _ in 0..<200 where session.confirmations.pending == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }

        return session.confirmations.pending
    }

    private func sentDel(_ client: MockRedisClient) async -> Bool {
        await client.executedCommandStrings.contains { $0.uppercased().hasPrefix("DEL ") }
    }

    @Test func productionDeleteSkipsThePopoverAndAsksOnce() async throws {
        let client = MockRedisClient(responses: ["DEL": .integer(1)])
        let model = await makeModel(.production, client: client)
        #expect(!model.deleteRequiresConfirmation)

        model.requestDelete(key)
        #expect(model.pendingDeleteKey == nil)
        let pending = try #require(await waitForPending(model.session))
        #expect(pending.actionID == KeyConfirmations.deleteKey)
        model.session.confirmations.resolve(confirmed: false)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!(await sentDel(client)))
    }

    @Test func unspecifiedDeleteUsesOnlyThePopover() async {
        let client = MockRedisClient(responses: ["DEL": .integer(1)])
        let model = await makeModel(.unspecified, client: client)
        model.requestDelete(key)
        #expect(model.pendingDeleteKey == key)
        await model.deleteKey(key)
        #expect(model.session.confirmations.pending == nil)
        #expect(await sentDel(client))
    }

    @Test func switchingKeysWithUnsavedEditsAsksFirst() async throws {
        let model = await makeModel(.unspecified, client: MockRedisClient())
        let first = Data("a".utf8)
        let second = Data("b".utf8)
        model.select(first)
        let state = try #require(model.details)
        state.hasUnsavedChanges = true

        model.select(second)
        #expect(model.selectedKey == first)
        #expect(model.details === state)
        let pending = try #require(model.pendingSelection)
        #expect(pending.key == second)

        model.discardChanges(pending)
        #expect(model.pendingSelection == nil)
        #expect(model.selectedKey == second)
        #expect(model.details?.key == second)
    }

    @Test func switchingKeysWithoutEditsDoesNotAsk() async {
        let model = await makeModel(.unspecified, client: MockRedisClient())
        model.select(Data("a".utf8))
        model.select(Data("b".utf8))
        #expect(model.pendingSelection == nil)
        #expect(model.selectedKey == Data("b".utf8))
    }

    @Test func developmentDeletesWithoutAsking() async {
        let client = MockRedisClient(responses: ["DEL": .integer(1)])
        let model = await makeModel(.development, client: client)
        #expect(!model.deleteRequiresConfirmation)
        await model.deleteKey(key)
        #expect(await sentDel(client))
    }
}

@MainActor
struct BrowserHexFilterTests {
    @Test func hexFilterIsReadAsBytesWhileNamesShowAsHex() {
        var config = DatabaseConfig(name: "Mock")
        config.keyNameFormat = .hex
        let model = BrowserViewModel(session: RedisTestServer.mockSession(config: config))
        model.patternText = "ff fe*"
        model.applyPattern()
        #expect(model.scanPattern == "\\xff\\xfe*")
        #expect(KeyPattern.matchBytes(model.scanPattern) == Data([0xFF, 0xFE, 0x2A]))

        model.patternText = "user:*"
        model.applyPattern()
        #expect(model.scanPattern == "user:*")
    }

    @Test func textFilterIsUnchangedForUnicodeNames() {
        let model = BrowserViewModel(session: RedisTestServer.mockSession())
        model.patternText = "ff*"
        model.applyPattern()
        #expect(model.scanPattern == "ff*")
    }
}
