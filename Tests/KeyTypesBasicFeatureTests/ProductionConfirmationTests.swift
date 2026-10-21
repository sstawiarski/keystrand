import Foundation
@testable import KeyTypesBasicFeature
import RedisCore
import TestSupport
import Testing

@MainActor
struct ProductionConfirmationTests {
    private let key = Data("user:1".utf8)

    private func makeSession(_ environment: DatabaseEnvironment,
                             client: MockRedisClient = MockRedisClient()) async -> DatabaseSession {
        let session = RedisTestServer.mockSession(client, config: DatabaseConfig(name: "Mock", environment: environment))
        await session.connect()
        return session
    }

    private func context(_ session: DatabaseSession, type: KeyType = .string,
                         onDeleted: @escaping @MainActor () -> Void = {}) -> KeyDetailsContext {
        KeyDetailsContext(session: session, key: key, type: type, state: KeyDetailsState(key: key),
                          onKeyDeleted: onDeleted)
    }

    private func waitForPending(_ session: DatabaseSession) async -> ConfirmationRequest? {
        for _ in 0..<200 where session.confirmations.pending == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }

        return session.confirmations.pending
    }

    private func sent(_ client: MockRedisClient, _ verb: String) async -> Bool {
        await client.executedCommandStrings.contains { $0.uppercased().hasPrefix(verb + " ") }
    }

    @Test func headerDeleteAsksOnceWithTheProductionConfirmation() async throws {
        let client = MockRedisClient(responses: ["DEL": .integer(1)])
        let session = await makeSession(.production, client: client)
        let model = KeyHeaderViewModel(context: context(session))
        #expect(model.skipsDeleteConfirmation)

        let task = Task { await model.deleteKey() }
        let pending = try #require(await waitForPending(session))
        #expect(pending.actionID == KeyConfirmations.deleteKey)
        #expect(!pending.requiresTyping)
        session.confirmations.resolve(confirmed: false)
        await task.value
        #expect(!(await sent(client, "DEL")))
    }

    @Test func headerDeleteUsesOnlyThePopoverOutsideProduction() async {
        let client = MockRedisClient(responses: ["DEL": .integer(1)])
        let session = await makeSession(.unspecified, client: client)
        var deleted = 0
        let model = KeyHeaderViewModel(context: context(session) { deleted += 1 })
        #expect(!model.skipsDeleteConfirmation)
        await model.deleteKey()
        #expect(session.confirmations.pending == nil)
        #expect(await sent(client, "DEL"))
        #expect(deleted == 1)

        let development = KeyHeaderViewModel(context: context(await makeSession(.development)))
        #expect(development.skipsDeleteConfirmation)
    }

    @Test func listRemoveAsksOnProduction() async throws {
        let client = MockRedisClient(responses: ["LPOP": .bulkArray(["a"]), "RPOP": .bulkArray(["a"])])
        let session = await makeSession(.production, client: client)
        let model = ListKeyViewModel(context: context(session, type: .list))
        #expect(model.skipsRemoveConfirmation)
        model.removeCountText = "1"

        let task = Task { await model.submitRemove() }
        let pending = try #require(await waitForPending(session))
        #expect(pending.actionID == KeyConfirmations.removeItems)
        session.confirmations.resolve(confirmed: false)
        #expect(await task.value == nil)
        #expect(!(await sent(client, "LPOP")))
        #expect(!(await sent(client, "RPOP")))
    }

    @Test func refreshLockIsScopedToItsState() {
        let first = KeyDetailsState(key: key)
        let second = KeyDetailsState(key: key)
        RefreshLock.set(first, owner: "value", locked: true)
        RefreshLock.set(first, owner: "header", locked: true)
        #expect(first.isRefreshDisabled)
        #expect(!second.isRefreshDisabled)
        RefreshLock.set(first, owner: "value", locked: false)
        #expect(first.isRefreshDisabled)
        RefreshLock.set(first, owner: "header", locked: false)
        #expect(!first.isRefreshDisabled)
    }

    @Test func keyNotFoundClosesTheDetails() async {
        let session = await makeSession(.unspecified)
        var deleted = 0
        let details = context(session) { deleted += 1 }
        details.report(KeyOperationError.keyNotFound)
        details.report(KeyValueError.indexOutOfRange)
        #expect(deleted == 1)
        #expect(session.toasts.toasts.count == 2)
    }
}

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis))
struct LiveProductionConfirmationTests {
    @Test func hashFieldTTLZeroAsksOnProduction() async throws {
        let h = try await LiveHarness.make("hprod")
        defer { Task { await h.cleanup() } }
        let key = h.key("h")
        try await h.run(["HSET", .data(key), "f", "v", "g", "w"])
        h.session.confirmations.isProduction = true
        let model = HashKeyViewModel(context: h.context(key, type: .hash))
        await model.load()
        guard model.supportsFieldTTL else { return }

        model.beginTTLEdit(Data("f".utf8))
        model.ttlDraft = "0"
        let task = Task { await model.saveTTL() }
        for _ in 0..<200 where h.session.confirmations.pending == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }

        let pending = try #require(h.session.confirmations.pending)
        #expect(pending.actionID == KeyConfirmations.removeItems)
        h.session.confirmations.resolve(confirmed: false)
        #expect(await task.value == false)
        #expect(try await h.run(["HEXISTS", .data(key), "f"]).intValue == 1)
    }
}
