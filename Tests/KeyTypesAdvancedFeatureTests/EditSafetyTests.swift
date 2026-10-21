import Foundation
@testable import KeyTypesAdvancedFeature
import RedisCore
import RedisUI
import TestSupport
import Testing

struct ScoreNormalizationTests {
    @Test func exponentAndHexScoresKeepTheirValue() {
        #expect(ZSetCommands.normalizeScore("1e5") == "1e5")
        #expect(ZSetCommands.normalizeScore("-2.5e-3") == "-2.5e-3")
        #expect(ZSetCommands.normalizeScore("1e+20") == "1e+20")
        #expect(ZSetCommands.normalizeScore("0x1p3") == "8")
        #expect(ZSetCommands.normalizeScore(" 3.5 ") == "3.5")
        #expect(ZSetCommands.normalizeScore("12.") == "12")
        #expect(ZSetCommands.normalizeScore("1e400") == "")
        #expect(ZSetCommands.normalizeScore("abc") == "")
        #expect(ZSetCommands.normalizeScore(".") == "")
        for text in ["1e5", "-2.5e-3", "1e+20", "0x1p3", "7", "-0.25"] {
            #expect(Double(ZSetCommands.normalizeScore(text)) == Double(text))
            #expect(ZSetCommands.scoreError(text) == nil)
        }

        #expect(ZSetCommands.scoreError("1e") == "Enter a number")
        #expect(ZSetCommands.scoreError("inf") == "Enter a number")
    }
}

struct FilterAutocompleteCaretTests {
    private let keys = ["price", "category", "year", "Priority"]

    @Test func tokenFollowsTheCaret() {
        let text = ".pr > 5 and .year > 1"
        #expect(VectorSetCommands.filterSuggestions(text: text, caret: 3, keys: keys) == ["Priority", "price"])
        #expect(VectorSetCommands.filterSuggestions(text: text, caret: 2, keys: keys) == ["Priority", "price"])
        #expect(VectorSetCommands.filterSuggestions(text: text, caret: 4, keys: keys).isEmpty)
        #expect(VectorSetCommands.filterToken(in: text, caret: 0) == nil)
        let token = VectorSetCommands.filterToken(in: text, caret: 2)
        #expect(token != nil)
        #expect(token?.start == 0)
        #expect(token?.prefix == "p")
        #expect(token?.word == "pr")
    }

    @Test func keysUsedAfterTheTokenAreExcluded() {
        #expect(VectorSetCommands.filterSuggestions(text: ". and .year > 1", caret: 1, keys: keys) == ["Priority", "category", "price"])
    }

    @Test func acceptingReplacesTheWholeToken() throws {
        let applied = try #require(VectorSetCommands.applySuggestion("price", to: ".pr > 5 and .year > 1", caret: 2))
        #expect(applied.text == ".price > 5 and .year > 1")
        #expect(applied.caret == 6)
        #expect(VectorSetCommands.index(in: "a😀b", utf16Offset: 2) == "a😀b".index(after: "a😀b".startIndex))
    }
}

@MainActor
struct VectorSetFormModelTests {
    private func makeModel(_ client: MockRedisClient = MockRedisClient()) -> VectorSetViewModel {
        let session = RedisTestServer.mockSession(client)
        let key = Data("v".utf8)
        return VectorSetViewModel(context: KeyDetailsContext(session: session, key: key, type: .vectorSet,
                                                             state: KeyDetailsState(key: key)))
    }

    @Test func filterCompletionsReplaceTheTokenAtTheCaret() {
        let model = makeModel()
        model.mergeAttributeKeys([#"{"price":1,"category":"a"}"#])
        model.filter = "."
        #expect(model.filterSuggestions == ["category", "price"])
        #expect(model.filterCompletions.map(\.text) == [".category", ".price"])

        model.filter = ".price > 1 and ."
        model.filterCaret = nil
        #expect(model.filterSuggestions == ["category"])
        #expect(model.filterCompletions.first?.text == ".price > 1 and .category")

        model.filter = ".pr > 1"
        model.filterCaret = 3
        #expect(model.filterCompletions.first?.text == ".price > 1")
        #expect(model.applySuggestion("price") == 6)
        #expect(model.filter == ".price > 1")

        model.filter = "price > 1"
        model.filterCaret = nil
        #expect(model.filterCompletions.isEmpty)
    }

    @Test func commandPreviewIsDebounced() async throws {
        let model = makeModel()
        model.mode = .element
        model.queryText = "e1"
        #expect(model.isBuildingPreview)
        #expect(model.debouncedPreview == nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.isBuildingPreview, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(!model.isBuildingPreview)
        #expect(model.debouncedPreview?.hasPrefix("VSIM v ELE e1") == true)
    }

    @Test func attributeSaveDoesNotLeakIntoAnotherDrawer() async {
        let client = MockRedisClient(responses: ["VSETATTR": .integer(1), "VGETATTR": .bulk(#"{"x":1}"#)])
        let model = makeModel(client)
        let a = Data("a".utf8)
        let b = Data("b".utf8)
        model.details = ElementDetailsState(name: a, draftAttributes: #"{"x":1}"#, isEditingAttributes: true, isLoading: false)
        let save = Task { await model.saveAttributes() }
        await Task.yield()
        model.details = ElementDetailsState(name: b, attributes: #"{"y":2}"#, draftAttributes: #"{"y":2}"#, isLoading: false)
        await save.value
        #expect(await client.executedCommandStrings.contains(#"VSETATTR v a {"x":1}"#))
        #expect(model.details?.name == b)
        #expect(model.details?.attributes == #"{"y":2}"#)
        #expect(model.details?.draftAttributes == #"{"y":2}"#)
        #expect(model.details?.isSaving == false)
    }

    @Test func attributeDraftPausesRefreshOnlyWhileChanged() {
        let state = KeyDetailsState(key: Data("v".utf8))
        let session = RedisTestServer.mockSession(MockRedisClient())
        let model = VectorSetViewModel(context: KeyDetailsContext(session: session, key: Data("v".utf8), type: .vectorSet,
                                                                  state: state))
        model.details = ElementDetailsState(name: Data("a".utf8), attributes: #"{"x":1}"#,
                                            draftAttributes: #"{"x":1}"#, isLoading: false)
        #expect(!state.isRefreshDisabled)
        model.updateDraftAttributes(#"{"x":2}"#)
        #expect(model.details?.isEditingAttributes == true)
        #expect(state.isRefreshDisabled)
        model.revertDraftAttributes()
        #expect(model.details?.isEditingAttributes == false)
        #expect(!state.isRefreshDisabled)
        model.updateDraftAttributes("not json")
        #expect(model.draftAttributesWarning != nil)
        model.details = nil
        #expect(!state.isRefreshDisabled)
    }
}

struct ArraySearchDisplayRowTests {
    private func row(_ index: String) -> ArrayRow {
        ArrayRow(element: ArrayElement(index: index, value: Data(index.utf8)), formatted: nil)
    }

    @Test func contextBandFollowsItsCenterMatch() {
        let results = [row("2"), row("9")]
        #expect(ArraySearchDisplayRow.rows(results: results, band: nil).map(\.id) == ["2", "9"])
        let band = ArrayContextBand(center: "2", rows: [row("1"), row("2"), row("3")])
        let rows = ArraySearchDisplayRow.rows(results: results, band: band)
        #expect(rows.map(\.id) == ["2", "context:1", "context:2", "context:3", "9"])
        #expect(rows.filter(\.isCenter).map(\.id) == ["2", "context:2"])
        #expect(rows.filter(\.isContext).count == 3)
        #expect(Set(rows.map(\.id)).count == rows.count)
    }
}

@MainActor
struct JSONEditingRefreshTests {
    @Test func refreshIsSkippedWhileEditing() async {
        let client = MockRedisClient()
        let session = RedisTestServer.mockSession(client)
        let key = Data("j".utf8)
        let state = KeyDetailsState(key: key)
        let model = JSONKeyViewModel(context: KeyDetailsContext(session: session, key: key, type: .json, state: state))
        model.setEditing(true)
        #expect(state.isRefreshDisabled)
        await model.refresh()
        #expect(await client.executedCommands.isEmpty)
        model.setEditing(false)
        #expect(!state.isRefreshDisabled)
    }

    @Test func legacyPathDialectWhenModuleVersionIsUnknown() async throws {
        let client = MockRedisClient(responses: ["JSON.TYPE": .bulk("object"), "JSON.OBJLEN": .integer(2),
                                                 "JSON.GET": .bulk(#"{"a":1,"b":[1,2]}"#), "JSON.SET": .ok])
        let session = RedisTestServer.mockSession(client)
        #expect(session.capabilities.jsonMajorVersion == nil)
        let key = Data("j".utf8)
        let model = JSONKeyViewModel(context: KeyDetailsContext(session: session, key: key, type: .json,
                                                                state: KeyDetailsState(key: key)))
        await model.load()
        #expect(model.isFullyLoaded)
        let full = try #require(model.tree.root.fullValue)
        #expect(JSONLiteral.format(full) == #"{"a":1,"b":[1,2]}"#)
        let reads = await client.executedCommandStrings
        #expect(reads.contains("JSON.TYPE j ."))
        #expect(reads.contains("JSON.GET j ."))

        try await model.actions.setValue?(JSONPath.root.appending(key: "a"), "5")
        let write = await client.executedCommandStrings.first { $0.hasPrefix("JSON.SET") }
        #expect(write == "JSON.SET j \(JSONPath.root.appending(key: "a").legacy) 5")
        #expect(write?.hasPrefix("JSON.SET j $") == false)
    }

    /// The tree asks about duplicate keys before calling `setValue`, so the view model writes straight away.
    @Test func duplicateKeysAreWrittenWithoutWaiting() async throws {
        let client = MockRedisClient(responses: ["JSON.TYPE": .bulk("object"), "JSON.OBJLEN": .integer(1),
                                                 "JSON.GET": .bulk(#"{"a":1}"#), "JSON.SET": .ok])
        let session = RedisTestServer.mockSession(client)
        let key = Data("j".utf8)
        let model = JSONKeyViewModel(context: KeyDetailsContext(session: session, key: key, type: .json,
                                                                state: KeyDetailsState(key: key)))
        try await model.actions.setValue?(.root, #"{"a":1,"a":2}"#)
        let write = await client.executedCommandStrings.first { $0.hasPrefix("JSON.SET") }
        #expect(write?.hasSuffix(#"{"a":1,"a":2}"#) == true)
    }
}

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis))
struct LiveEditSafetyTests {
    @Test func exponentScoreIsSavedAsTyped() async throws {
        let h = try await LiveHarness.make("zexp")
        defer { Task { await h.cleanup() } }
        let key = h.key("z")
        try await h.run(["ZADD", .data(key), "1", "m", "2", "n"])
        let model = ZSetViewModel(context: h.context(key, type: .zset))
        await model.load()
        await model.updateScore(member: Data("m".utf8), score: "1e5")
        let reply = try await h.run(["ZSCORE", .data(key), "m"])
        #expect((reply.doubleValue ?? reply.stringValue.flatMap(Double.init)) == 100_000)
        #expect(model.rows.first { $0.id == Data("m".utf8) }?.member.score == "1e5")
    }

    @Test func arrayEditsKeepUnchangedValuesAndAskBeforeUnicodeFallback() async throws {
        let h = try await LiveHarness.make("arre")
        defer { Task { await h.cleanup() } }
        #expect(h.session.capabilities.supportsArray)
        let key = h.key("a")
        try await h.run(["ARSET", .data(key), "0", #"{"a": 1}"#, "plain"])
        let settings = h.session.services.settings
        settings.browser.valueFormat = .json
        let model = ArrayViewModel(context: h.context(key, type: .array))
        await model.load()
        #expect(model.needsNonUnicodeGuard)

        model.beginEditing(model.rows[0])
        #expect(model.editingIndex == "0")
        #expect(await model.saveEdit())
        #expect(model.editingIndex == nil)
        #expect(try await h.run(["ARGET", .data(key), "0"]).stringValue == #"{"a": 1}"#)

        model.beginEditing(model.rows[0])
        model.editText = "{not json"
        #expect(await model.saveEdit() == false)
        #expect(model.pendingUnicodeSave == ArrayPendingSave(index: "0", text: "{not json"))
        #expect(try await h.run(["ARGET", .data(key), "0"]).stringValue == #"{"a": 1}"#)
        #expect(await model.confirmUnicodeSave())
        #expect(model.pendingUnicodeSave == nil)
        #expect(try await h.run(["ARGET", .data(key), "0"]).stringValue == "{not json")

        model.pendingEditAfterFormatChange = "1"
        settings.browser.valueFormat = .unicode
        await model.formatChanged()
        #expect(!model.needsNonUnicodeGuard)
        #expect(model.editingIndex == "1")
        #expect(model.editText == "plain")
        #expect(await model.saveEdit())
        #expect(model.editingIndex == nil)

        model.beginEditing(model.rows[1])
        model.editText = "changed"
        #expect(await model.saveEdit())
        #expect(try await h.run(["ARGET", .data(key), "1"]).stringValue == "changed")
    }
}
