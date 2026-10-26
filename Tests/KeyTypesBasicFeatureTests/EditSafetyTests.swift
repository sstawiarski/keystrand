import Foundation
@testable import KeyTypesBasicFeature
import RedisCore
import TestSupport
import Testing

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis))
struct LiveEditSafetyTests {

    private func fieldTTL(_ h: LiveHarness, _ key: Data, _ field: String) async throws -> Int {
        Int(try await h.run(["HTTL", .data(key), "FIELDS", "1", .string(field)]).arrayValue?.first?.intValue ?? -9)
    }

    // MARK: - Hash field TTL survives value writes

    @Test(RedisTestServer.needs(.hashFieldTTL)) func hashValueEditKeepsFieldTTL() async throws {
        let h = try await LiveHarness.make("hkeep")
        defer { Task { await h.cleanup() } }
        let key = h.key("h")
        try await h.run(["HSET", .data(key), "f", "v", "g", "w"])
        try await h.run(["HEXPIRE", .data(key), "1000", "FIELDS", "1", "f"])
        let model = HashKeyViewModel(context: h.context(key, type: .hash))
        await model.load()

        model.beginEdit(Data("f".utf8))
        model.editDraft = "v2"
        #expect(await model.saveEdit())
        #expect(try await h.run(["HGET", .data(key), "f"]).stringValue == "v2")
        #expect(try await fieldTTL(h, key, "f") > 990)
        #expect((model.rows.first { $0.field == Data("f".utf8) }?.expire ?? 0) > 990)

        model.beginEdit(Data("g".utf8))
        model.editDraft = "w2"
        #expect(await model.saveEdit())
        #expect(try await fieldTTL(h, key, "g") == -1)
    }

    @Test(RedisTestServer.needs(.hashFieldTTL)) func hashAddExistingFieldWithoutTTLKeepsFieldTTL() async throws {
        let h = try await LiveHarness.make("hadd")
        defer { Task { await h.cleanup() } }
        let key = h.key("h")
        try await h.run(["HSET", .data(key), "f", "v", "e", "x"])
        try await h.run(["HEXPIRE", .data(key), "1000", "FIELDS", "2", "f", "e"])
        let model = HashKeyViewModel(context: h.context(key, type: .hash))
        await model.load()

        model.openAddPanel()
        model.addRows = [.init(field: "f", value: "new"), .init(field: "e", value: "y", ttl: "50"), .init(field: "n", value: "1")]
        #expect(await model.submitAdd())
        #expect(try await h.run(["HGET", .data(key), "f"]).stringValue == "new")
        #expect(try await fieldTTL(h, key, "f") > 990)
        let typed = try await fieldTTL(h, key, "e")
        #expect(typed > 0 && typed <= 50)
        #expect(try await fieldTTL(h, key, "n") == -1)
    }

    @Test(RedisTestServer.needs(.hashFieldTTL), arguments: [HashService.FieldTTLStrategy.keepTTL, .restoreExpireTime])
    func hashServiceStrategiesKeepFieldTTL(_ strategy: HashService.FieldTTLStrategy) async throws {
        let h = try await LiveHarness.make("hstrat")
        defer { Task { await h.cleanup() } }
        let key = h.key("h")
        try await h.run(["HSET", .data(key), "f", "v", "plain", "p"])
        try await h.run(["HEXPIRE", .data(key), "1000", "FIELDS", "1", "f"])
        let service = HashService(session: h.session)
        try await service.setFields(key, [HashField(field: Data("f".utf8), value: Data("v2".utf8)),
                                          HashField(field: Data("plain".utf8), value: Data("p2".utf8)),
                                          HashField(field: Data("t".utf8), value: Data("1".utf8), expire: 30)],
                                    applyExpire: true, strategy: strategy)
        #expect(try await h.run(["HGET", .data(key), "f"]).stringValue == "v2")
        #expect(try await h.run(["HGET", .data(key), "plain"]).stringValue == "p2")
        #expect(try await fieldTTL(h, key, "f") > 990)
        #expect(try await fieldTTL(h, key, "plain") == -1)
        let typed = try await fieldTTL(h, key, "t")
        #expect(typed > 0 && typed <= 30)
    }

    @Test func hashUnchangedJSONSaveDoesNotRewrite() async throws {
        let h = try await LiveHarness.make("hjson")
        defer { Task { await h.cleanup() } }
        let key = h.key("h")
        let original = "{ \"a\" : 1,\n \"b\": \"\\u0041\" }"
        try await h.run(["HSET", .data(key), "f", .string(original)])
        h.session.services.settings.browser.valueFormat = .json
        let context = h.context(key, type: .hash)
        let model = HashKeyViewModel(context: context)
        await model.load()
        model.beginEdit(Data("f".utf8))
        #expect(model.editingField != nil)
        #expect(await model.saveEdit())
        #expect(model.editingField == nil)
        #expect(!context.state.isRefreshDisabled)
        #expect(try await h.run(["HGET", .data(key), "f"]).stringValue == original)
    }

    // MARK: - String

    @Test func stringUnchangedJSONSaveDoesNotRewrite() async throws {
        let h = try await LiveHarness.make("sjson")
        defer { Task { await h.cleanup() } }
        let key = h.key("s")
        let original = "{\n  \"a\" : 1, \"b\": [1,2]\n}"
        try await h.run(["SET", .data(key), .string(original)])
        h.session.services.settings.browser.valueFormat = .json
        let context = h.context(key, type: .string)
        let model = StringKeyViewModel(context: context)
        await model.load()
        model.beginEdit()
        #expect(model.isEditing)
        #expect(await model.saveEdit())
        #expect(!model.isEditing)
        #expect(!context.state.isRefreshDisabled)
        #expect(try await h.run(["GET", .data(key)]).stringValue == original)
    }

    // MARK: - List

    @Test func listEditFailsWhenElementChanged() async throws {
        let h = try await LiveHarness.make("lcas")
        defer { Task { await h.cleanup() } }
        let key = h.key("l")
        try await h.run(["RPUSH", .data(key), "a", "b", "c"])
        let model = ListKeyViewModel(context: h.context(key, type: .list))
        await model.load()

        model.beginEdit(1)
        model.editDraft = "edited"
        try await h.run(["LPUSH", .data(key), "z"])
        #expect(!(await model.saveEdit()))
        #expect(try await h.run(["LRANGE", .data(key), "0", "-1"]).arrayValue?.compactMap(\.stringValue) == ["z", "a", "b", "c"])
        #expect(h.session.toasts.toasts.contains { $0.message == KeyValueError.elementChanged.localizedDescription
            || $0.title == KeyValueError.elementChanged.localizedDescription })
        #expect(model.editingIndex == 1)

        model.cancelEdit()
        await model.load()
        model.beginEdit(2)
        model.editDraft = "B"
        #expect(await model.saveEdit())
        #expect(try await h.run(["LINDEX", .data(key), "2"]).stringValue == "B")
    }

    @Test func listPanelsCancelEditBeforeTheListShifts() async throws {
        let h = try await LiveHarness.make("lpanel")
        defer { Task { await h.cleanup() } }
        let key = h.key("l")
        try await h.run(["RPUSH", .data(key), "a", "b", "c"])
        let context = h.context(key, type: .list)
        let model = ListKeyViewModel(context: context)
        await model.load()

        model.beginEdit(1)
        model.editDraft = "edited"
        model.openPanel(.add)
        #expect(model.editingIndex == nil)
        #expect(!context.state.isRefreshDisabled)
        model.addDestination = .head
        model.addRows = [.init(element: "z")]
        #expect(await model.submitAdd())
        #expect(!(await model.saveEdit()))
        #expect(try await h.run(["LRANGE", .data(key), "0", "-1"]).arrayValue?.compactMap(\.stringValue) == ["z", "a", "b", "c"])
    }

    @Test func listServiceCompareAndSet() async throws {
        let h = try await LiveHarness.make("lsvc")
        defer { Task { await h.cleanup() } }
        let key = h.key("l")
        try await h.run(["RPUSH", .data(key), "a", "b"])
        let service = ListService(session: h.session)
        try await service.set(key, index: 0, value: Data("A".utf8), expected: Data("a".utf8))
        #expect(try await h.run(["LINDEX", .data(key), "0"]).stringValue == "A")
        await #expect(throws: KeyValueError.elementChanged) {
            try await service.set(key, index: 1, value: Data("X".utf8), expected: Data("nope".utf8))
        }
        await #expect(throws: KeyValueError.indexOutOfRange) {
            try await service.set(key, index: 9, value: Data("X".utf8), expected: Data("b".utf8))
        }
        await #expect(throws: KeyOperationError.keyNotFound) {
            try await service.set(h.key("missing"), index: 0, value: Data("X".utf8), expected: Data("b".utf8))
        }
    }

    @Test func listUnchangedSaveDoesNotWrite() async throws {
        let h = try await LiveHarness.make("lsame")
        defer { Task { await h.cleanup() } }
        let key = h.key("l")
        let original = "[1,   2]"
        try await h.run(["RPUSH", .data(key), .string(original)])
        h.session.services.settings.browser.valueFormat = .json
        let model = ListKeyViewModel(context: h.context(key, type: .list))
        await model.load()
        model.beginEdit(0)
        #expect(model.editingIndex == 0)
        #expect(await model.saveEdit())
        #expect(model.editingIndex == nil)
        #expect(try await h.run(["LINDEX", .data(key), "0"]).stringValue == original)
    }

    // MARK: - Cancellable loads

    @Test func reloadAndRefreshUseOneLoad() async throws {
        let h = try await LiveHarness.make("loads")
        defer { Task { await h.cleanup() } }
        let key = h.key("s")
        try await h.run(["SADD", .data(key), "a", "b"])
        let model = SetKeyViewModel(context: h.context(key, type: .set))
        model.reload()
        #expect(model.loads.isRunning)
        model.refresh()
        await model.loads.wait()
        #expect(!model.loads.isRunning)
        #expect(model.rows.count == 2)
        #expect(model.loadError == nil)

        model.reload()
        model.viewDidDisappear()
        #expect(!model.loads.isRunning)
        #expect(model.loadError == nil)
    }
}

@MainActor
@Suite struct LoadTaskSlotTests {
    @Test func newRunCancelsThePreviousOne() async {
        let slot = LoadTaskSlot()
        var firstCancelled = false
        var secondFinished = false
        slot.run {
            try? await Task.sleep(for: .seconds(5))
            firstCancelled = Task.isCancelled
        }
        slot.run { secondFinished = true }
        await slot.wait()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(firstCancelled)
        #expect(secondFinished)
        #expect(!slot.isRunning)
    }

    @Test func refreshIsSkippedWhileRunning() async {
        let slot = LoadTaskSlot()
        var runs = 0
        slot.run {
            runs += 1
            try? await Task.sleep(for: .milliseconds(100))
        }
        slot.runUnlessRunning { runs += 1 }
        await slot.wait()
        #expect(runs == 1)
        slot.runUnlessRunning { runs += 1 }
        await slot.wait()
        #expect(runs == 2)
    }

    @Test func cancelStopsTheRunningLoad() async {
        let slot = LoadTaskSlot()
        var cancelled = false
        slot.run {
            try? await Task.sleep(for: .seconds(5))
            cancelled = Task.isCancelled
        }
        slot.cancel()
        #expect(!slot.isRunning)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(cancelled)
    }
}

@Suite struct KeyHeaderRefreshTests {
    @Test func autoRefreshPostfixIsTheKeyType() {
        #expect(KeyHeaderLabels.refreshPostfix(for: .string) == "string")
        #expect(KeyHeaderLabels.refreshPostfix(for: .hash) == "hash")
        #expect(KeyHeaderLabels.refreshPostfix(for: .json) == "ReJSON-RL")
        #expect(KeyHeaderLabels.refreshPostfix(for: .unknown("MBbloom--")) == "MBbloom--")
    }
}
