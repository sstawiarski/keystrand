import Foundation
@testable import KeyTypesBasicFeature
import RedisCore
import TestSupport
import Testing

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis))
struct LiveKeyTypeTests {

    // MARK: - Header

    @Test func headerLoadsInfoAndEditsTTL() async throws {
        let h = try await LiveHarness.make("hdr")
        defer { Task { await h.cleanup() } }
        let key = h.key("hash")
        try await h.run(["HSET", .data(key), "a", "1", "b", "2"])
        let context = h.context(key, type: .hash)
        let model = KeyHeaderViewModel(context: context)

        await model.loadInfo()
        let info = try #require(context.state.info)
        #expect(info.type == .hash)
        #expect(info.length == 2)
        #expect(info.ttl == -1)
        #expect((info.size ?? 0) > 0)

        await model.setTTL(1000)
        #expect((context.state.info?.ttl ?? 0) > 990)
        #expect(Int(try await h.run(["TTL", .data(key)]).intValue ?? 0) > 990)

        await model.setTTL(-1)
        #expect(context.state.info?.ttl == -1)
        #expect(try await h.run(["TTL", .data(key)]).intValue == -1)
        #expect(h.changedCount >= 2)
    }

    @Test func headerTTLZeroDeletesKey() async throws {
        let h = try await LiveHarness.make("hdr0")
        defer { Task { await h.cleanup() } }
        let key = h.key("s")
        try await h.run(["SET", .data(key), "v"])
        let model = KeyHeaderViewModel(context: h.context(key, type: .string))
        await model.setTTL(0)
        #expect(try await h.run(["EXISTS", .data(key)]).intValue == 0)
        #expect(h.deletedCount == 1)
    }

    @Test func headerRenameAndOverwrite() async throws {
        let h = try await LiveHarness.make("ren")
        defer { Task { await h.cleanup() } }
        let key = h.key("old")
        let taken = h.key("taken")
        try await h.pipeline([["SET", .data(key), "v1"], ["SET", .data(taken), "v2"]])
        let model = KeyHeaderViewModel(context: h.context(key, type: .string))

        let renamed = await model.rename(to: h.prefix + "taken")
        #expect(!renamed)
        #expect(model.pendingOverwriteName == taken)
        #expect(h.renamedTo.isEmpty)

        await model.confirmOverwrite()
        #expect(h.renamedTo == [taken])
        #expect(try await h.run(["GET", .data(taken)]).stringValue == "v1")
        #expect(try await h.run(["EXISTS", .data(key)]).intValue == 0)
    }

    @Test func headerRenameToFreeName() async throws {
        let h = try await LiveHarness.make("ren2")
        defer { Task { await h.cleanup() } }
        let key = h.key("a")
        try await h.run(["SET", .data(key), "v"])
        let model = KeyHeaderViewModel(context: h.context(key, type: .string))
        #expect(await model.rename(to: h.prefix + "b"))
        #expect(h.renamedTo == [h.key("b")])
        #expect(try await h.run(["EXISTS", .data(h.key("b"))]).intValue == 1)
    }

    @Test func headerDeleteAndRefresh() async throws {
        let h = try await LiveHarness.make("del")
        defer { Task { await h.cleanup() } }
        let key = h.key("l")
        try await h.run(["RPUSH", .data(key), "x"])
        let context = h.context(key, type: .list)
        let model = KeyHeaderViewModel(context: context)
        await model.refresh()
        #expect(context.state.refreshGeneration == 1)
        #expect(model.lastRefresh != nil)

        context.state.isRefreshDisabled = true
        await model.refresh()
        #expect(context.state.refreshGeneration == 1)
        context.state.isRefreshDisabled = false

        await model.deleteKey()
        #expect(h.deletedCount == 1)
        #expect(try await h.run(["EXISTS", .data(key)]).intValue == 0)
    }

    @Test func headerMissingKeyClosesDetails() async throws {
        let h = try await LiveHarness.make("miss")
        defer { Task { await h.cleanup() } }
        let model = KeyHeaderViewModel(context: h.context(h.key("nope"), type: .string))
        await model.loadInfo()
        #expect(h.deletedCount == 1)
        #expect(h.session.toasts.toasts.contains { $0.message == "Key with this name does not exist." })
    }

    @Test func headerBinaryKeyNameCannotBeRenamed() async throws {
        let h = try await LiveHarness.make("bin")
        defer { Task { await h.cleanup() } }
        let key = h.key("") + Data([0xFF, 0xFE])
        try await h.run(["SET", .data(key), "v"])
        let context = h.context(key, type: .string)
        let model = KeyHeaderViewModel(context: context)
        #expect(!model.canRename)
        await model.loadInfo()
        #expect(context.state.info?.length == 1)
    }

    @Test func headerSkipsMemoryUsageForLargeKeysWhenSizeColumnHidden() async throws {
        let h = try await LiveHarness.make("size")
        defer { Task { await h.cleanup() } }
        let key = h.key("big")
        try await h.run(["RPUSH", .data(key)] + (0..<50_000).map { RedisArgument.string(String($0)) })
        let context = h.context(key, type: .list)
        let model = KeyHeaderViewModel(context: context)

        await model.loadInfo()
        #expect((context.state.info?.size ?? 0) > 0)

        try await h.session.services.databaseSettingsStore.update(h.session.config.id) {
            $0.browserShownColumns = [.ttl]
            $0.didUserConfigureColumns = true
        }
        await model.loadInfo()
        #expect(context.state.info?.size == -1)
        #expect(context.state.info?.length == 50_000)
    }

    // MARK: - String

    @Test func stringPartialLoadAndLoadAll() async throws {
        let h = try await LiveHarness.make("str")
        defer { Task { await h.cleanup() } }
        let key = h.key("big")
        let text = String(repeating: "0123456789", count: 1_200)
        try await h.run(["SET", .data(key), .string(text)])
        let model = StringKeyViewModel(context: h.context(key, type: .string))

        await model.load()
        #expect(model.value?.count == 5_000)
        #expect(model.length == 12_000)
        #expect(!model.isFullyLoaded)
        #expect(model.showsFooter)
        #expect(model.displayFormat == .unicode)
        #expect(model.editBlockReason == ValueEditRules.loadEntireValue)
        #expect(model.copyText == nil)
        if case .text(let shown) = model.result?.content { #expect(shown.hasSuffix("…")) }

        await model.loadAll()
        #expect(model.isFullyLoaded)
        #expect(model.value?.count == 12_000)
        #expect(model.editBlockReason == nil)
        #expect(model.copyText == text)

        await model.load()
        #expect(model.isFullyLoaded)
    }

    @Test func stringEditKeepsTTL() async throws {
        let h = try await LiveHarness.make("stred")
        defer { Task { await h.cleanup() } }
        let key = h.key("s")
        try await h.run(["SET", .data(key), "before", "EX", "1000"])
        let context = h.context(key, type: .string)
        let model = StringKeyViewModel(context: context)
        await model.load()
        model.beginEdit()
        #expect(model.isEditing)
        #expect(context.state.isRefreshDisabled)
        #expect(model.editDraft == "before")
        model.editDraft = "after"
        #expect(await model.saveEdit())
        #expect(!model.isEditing)
        #expect(!context.state.isRefreshDisabled)
        #expect(try await h.run(["GET", .data(key)]).stringValue == "after")
        #expect(Int(try await h.run(["TTL", .data(key)]).intValue ?? 0) > 990)
        #expect(context.state.info?.length == 5)
    }

    @Test func stringJSONFormatEditCompacts() async throws {
        let h = try await LiveHarness.make("strjson")
        defer { Task { await h.cleanup() } }
        let key = h.key("j")
        try await h.run(["SET", .data(key), #"{"a":1}"#])
        h.session.services.settings.browser.valueFormat = .json
        let model = StringKeyViewModel(context: h.context(key, type: .string))
        await model.load()
        #expect(model.result?.jsonValue != nil)
        #expect(model.needsNonUnicodeGuard)
        model.beginEdit()
        #expect(model.editDraft.contains("\n"))
        model.editDraft = "{\n    \"a\": 2\n}"
        #expect(await model.saveEdit())
        #expect(try await h.run(["GET", .data(key)]).stringValue == #"{"a":2}"#)
    }

    @Test func stringBinaryValueEditBlockedInUnicode() async throws {
        let h = try await LiveHarness.make("strbin")
        defer { Task { await h.cleanup() } }
        let key = h.key("b")
        try await h.run(["SET", .data(key), .data(Data([0xFF, 0x00, 0x80]))])
        let model = StringKeyViewModel(context: h.context(key, type: .string))
        await model.load()
        #expect(model.editBlockReason?.hasPrefix(ValueEditRules.nonPrintableTitle) == true)
        h.session.services.settings.browser.valueFormat = .hex
        await model.formatChanged()
        #expect(model.editBlockReason == ValueEditRules.cannotEditFormat)
        if case .text(let hex) = model.result?.content { #expect(hex == "ff0080") }
    }

    @Test func stringDownloadWritesFullValue() async throws {
        let h = try await LiveHarness.make("strdl")
        defer { Task { await h.cleanup() } }
        let key = h.key("d")
        let bytes = Data((0..<20_000).map { UInt8($0 % 251) })
        try await h.run(["SET", .data(key), .data(bytes)])
        let model = StringKeyViewModel(context: h.context(key, type: .string))
        await model.load()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("string_value-\(UUID().uuidString)")
        #expect(await model.download(to: url))
        #expect(try Data(contentsOf: url) == bytes)
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    @Test func stringEmptyValue() async throws {
        let h = try await LiveHarness.make("strempty")
        defer { Task { await h.cleanup() } }
        let key = h.key("e")
        try await h.run(["SET", .data(key), ""])
        let model = StringKeyViewModel(context: h.context(key, type: .string))
        await model.load()
        #expect(model.isEmpty)
        #expect(model.isFullyLoaded)
        #expect(!model.showsFooter)
    }

    // MARK: - Hash

    @Test func hashPagesFilterAndLoadMore() async throws {
        let h = try await LiveHarness.make("hash")
        defer { Task { await h.cleanup() } }
        let key = h.key("h")
        var args: [RedisArgument] = ["HSET", .data(key)]
        for i in 0..<1_200 { args += [.string("f\(i)"), .string("v\(i)")] }
        try await h.run(args)
        let model = HashKeyViewModel(context: h.context(key, type: .hash))

        await model.load()
        #expect(model.total == 1_200)
        #expect(model.rows.count >= 500)
        #expect(model.rows.allSatisfy { $0.valuePreview != nil })
        while model.canLoadMore { await model.loadMore() }
        #expect(model.rows.count == 1_200)
        #expect(Set(model.rows.map(\.field)).count == 1_200)

        model.searchText = "f7"
        await model.applySearch()
        #expect(model.rows.map(\.field) == [Data("f7".utf8)])
        #expect(model.rows.first?.value == Data("v7".utf8))
        #expect(!model.canLoadMore)

        model.searchText = "f11*"
        await model.applySearch()
        while model.canLoadMore { await model.loadMore() }
        #expect(model.rows.count == 111)

        model.searchText = "missing"
        await model.applySearch()
        #expect(model.rows.isEmpty)
        #expect(model.loadError == nil)
    }

    @Test func hashEditDeleteAndAdd() async throws {
        let h = try await LiveHarness.make("hashed")
        defer { Task { await h.cleanup() } }
        let key = h.key("h")
        try await h.run(["HSET", .data(key), "a", "1", "b", "2"])
        let context = h.context(key, type: .hash)
        let model = HashKeyViewModel(context: context)
        await model.load()

        model.beginEdit(Data("a".utf8))
        #expect(model.editingField == Data("a".utf8))
        #expect(context.state.isRefreshDisabled)
        model.editDraft = "100"
        #expect(await model.saveEdit())
        #expect(try await h.run(["HGET", .data(key), "a"]).stringValue == "100")
        #expect(model.rows.first { $0.field == Data("a".utf8) }?.value == Data("100".utf8))
        #expect(!context.state.isRefreshDisabled)

        await model.deleteField(Data("b".utf8))
        #expect(model.total == 1)
        #expect(model.isLastItem)
        #expect(context.state.info?.length == 1)

        model.openAddPanel()
        model.addRows = [.init(field: "c", value: "3", ttl: "500"), .init(field: "d", value: "4")]
        #expect(await model.submitAdd())
        #expect(!model.isAddPanelOpen)
        #expect(model.total == 3)
        let ttl = try await h.run(["HTTL", .data(key), "FIELDS", "1", "c"]).arrayValue?.first?.intValue ?? -1
        #expect(ttl > 0)
        #expect(model.rows.first { $0.field == Data("c".utf8) }.flatMap(\.expire).map { $0 > 0 } == true)
    }

    @Test func hashFieldTTLEdits() async throws {
        let h = try await LiveHarness.make("hashttl")
        defer { Task { await h.cleanup() } }
        let key = h.key("h")
        try await h.run(["HSET", .data(key), "a", "1", "b", "2"])
        let model = HashKeyViewModel(context: h.context(key, type: .hash))
        await model.load()
        #expect(model.supportsFieldTTL)
        #expect(model.rows.allSatisfy { $0.expire == -1 })

        model.beginTTLEdit(Data("a".utf8))
        model.ttlDraft = "300"
        #expect(await model.saveTTL())
        #expect((model.rows.first { $0.field == Data("a".utf8) }?.expire ?? 0) > 290)

        model.beginTTLEdit(Data("a".utf8))
        model.ttlDraft = ""
        #expect(await model.saveTTL())
        #expect(model.rows.first { $0.field == Data("a".utf8) }?.expire == -1)

        model.beginTTLEdit(Data("a".utf8))
        model.ttlDraft = "120"
        #expect(await model.saveTTL())
        model.beginEdit(Data("a".utf8))
        model.editDraft = "edited"
        #expect(await model.saveEdit())
        let serverTTL = try await h.run(["HTTL", .data(key), "FIELDS", "1", "a"]).arrayValue?.first?.intValue
        #expect(model.rows.first { $0.field == Data("a".utf8) }?.expire == serverTTL.map(Int.init))

        model.beginTTLEdit(Data("b".utf8))
        model.ttlDraft = "0"
        #expect(await model.saveTTL())
        #expect(model.rows.map(\.field) == [Data("a".utf8)])
        #expect(try await h.run(["HEXISTS", .data(key), "b"]).intValue == 0)
    }

    @Test func hashDeletingLastFieldDeletesKey() async throws {
        let h = try await LiveHarness.make("hashlast")
        defer { Task { await h.cleanup() } }
        let key = h.key("h")
        try await h.run(["HSET", .data(key), "only", "1"])
        let model = HashKeyViewModel(context: h.context(key, type: .hash))
        await model.load()
        #expect(model.isLastItem)
        await model.deleteField(Data("only".utf8))
        #expect(h.deletedCount == 1)
    }

    @Test func hashBinaryFieldsAreBinarySafe() async throws {
        let h = try await LiveHarness.make("hashbin")
        defer { Task { await h.cleanup() } }
        let key = h.key("h")
        let field = Data([0xC3, 0x28, 0x00])
        try await h.run(["HSET", .data(key), .data(field), .data(Data([0xFF]))])
        let model = HashKeyViewModel(context: h.context(key, type: .hash))
        await model.load()
        let row = try #require(model.rows.first)
        #expect(row.field == field)
        #expect(model.editBlockReason(row) != nil)
        await model.deleteField(field)
        #expect(h.deletedCount == 1)
    }

    @Test func hashLargeValuePreviewIsBounded() async throws {
        let h = try await LiveHarness.make("hashbig")
        defer { Task { await h.cleanup() } }
        let key = h.key("h")
        let big = Data(String(repeating: "x", count: 2_000_000).utf8)
        try await h.run(["HSET", .data(key), "big", .data(big), "small", "1"])
        let model = HashKeyViewModel(context: h.context(key, type: .hash))
        await model.load()
        let row = try #require(model.rows.first { $0.field == Data("big".utf8) })
        #expect(row.value.count == big.count)
        #expect((row.valuePreview?.text.count ?? .max) <= ValueDisplayFormatter.collapsedLength + 1)
        await model.toggleExpanded(Data("big".utf8))
        if case .text(let text) = model.expandedResults[Data("big".utf8)]?.value.content {
            #expect(text.utf8.count == big.count)
        } else {
            Issue.record("expected text content")
        }
    }

    @Test func hashFormatChangeAndExpand() async throws {
        let h = try await LiveHarness.make("hashfmt")
        defer { Task { await h.cleanup() } }
        let key = h.key("h")
        try await h.run(["HSET", .data(key), "j", #"{"x":[1,2]}"#])
        let model = HashKeyViewModel(context: h.context(key, type: .hash))
        await model.load()
        await model.toggleExpanded(Data("j".utf8))
        #expect(model.expandedResults[Data("j".utf8)] != nil)
        h.session.services.settings.browser.valueFormat = .json
        model.pendingEditAfterFormatChange = nil
        await model.formatChanged()
        #expect(model.expanded.isEmpty)
        #expect(model.format == .json)
        #expect(model.rows.first?.valuePreview?.isValid == true)
        #expect(model.rows.first?.fieldPreview?.isValid == false)
    }

    @Test func valuePreviewSurvivesReloadAndFormatChange() async throws {
        let h = try await LiveHarness.make("preview")
        defer { Task { await h.cleanup() } }
        let hashKey = h.key("h")
        let listKey = h.key("l")
        let setKey = h.key("s")
        try await h.run(["HSET", .data(hashKey), "f", "hash-value"])
        try await h.run(["RPUSH", .data(listKey), "list-value"])
        try await h.run(["SADD", .data(setKey), "set-member"])

        let hash = HashKeyViewModel(context: h.context(hashKey, type: .hash))
        await hash.load()
        await hash.showPreview(Data("f".utf8))
        await hash.load()
        await hash.formatChanged()
        let hashPreview = try #require(hash.preview)
        #expect(hashPreview.title == "Value of “f”")
        #expect(hashPreview.copyText == "hash-value")
        if case .text(let text) = hashPreview.result?.content { #expect(text == "hash-value") } else {
            Issue.record("expected text content")
        }

        hash.closePreview()
        #expect(hash.preview == nil)

        let list = ListKeyViewModel(context: h.context(listKey, type: .list))
        await list.load()
        await list.showPreview(0)
        await list.load()
        #expect(list.preview?.title == "Element 0")
        #expect(list.preview?.result != nil)

        let set = SetKeyViewModel(context: h.context(setKey, type: .set))
        await set.load()
        await set.showPreview(Data("set-member".utf8))
        await set.load()
        #expect(set.preview?.copyText == "set-member")
        #expect(set.preview?.result != nil)
    }

    // MARK: - List

    @Test func listPagesIndexSearchAndEdit() async throws {
        let h = try await LiveHarness.make("list")
        defer { Task { await h.cleanup() } }
        let key = h.key("l")
        try await h.run(["RPUSH", .data(key)] + (0..<1_200).map { .string("e\($0)") })
        let model = ListKeyViewModel(context: h.context(key, type: .list))

        await model.load()
        #expect(model.total == 1_200)
        #expect(model.rows.count == 500)
        #expect(model.rows.last?.index == 499)
        while model.canLoadMore { await model.loadMore() }
        #expect(model.rows.count == 1_200)
        #expect(model.rows[1_199].value == Data("e1199".utf8))

        model.searchText = "42"
        await model.applySearch()
        #expect(model.rows.map(\.index) == [42])
        #expect(model.rows.first?.value == Data("e42".utf8))

        model.beginEdit(42)
        model.editDraft = "changed"
        #expect(await model.saveEdit())
        #expect(try await h.run(["LINDEX", .data(key), "42"]).stringValue == "changed")

        model.searchText = "5000"
        await model.applySearch()
        #expect(model.rows.isEmpty)
        #expect(model.searchError == "Index is out of range.")

        model.searchText = ""
        await model.applySearch()
        #expect(model.rows.count == 500)
    }

    @Test func listPushAndPop() async throws {
        let h = try await LiveHarness.make("listpp")
        defer { Task { await h.cleanup() } }
        let key = h.key("l")
        try await h.run(["RPUSH", .data(key), "a", "b", "c"])
        let context = h.context(key, type: .list)
        let model = ListKeyViewModel(context: context)
        await model.load()

        model.openPanel(.add)
        #expect(context.state.isAddPanelOpen)
        model.addDestination = .head
        model.addRows = [.init(element: "h1"), .init(element: "h2")]
        #expect(await model.submitAdd())
        #expect(model.panel == nil)
        #expect(model.total == 5)
        #expect(model.rows.first?.value == Data("h2".utf8))

        model.openPanel(.remove)
        model.removeDestination = .tail
        model.removeCountText = "2"
        #expect(model.removeConfirmationMessage.hasPrefix("The last 2 elements of "))
        #expect(!model.removeDeletesKey)
        let removed = await model.submitRemove()
        #expect(removed == [Data("c".utf8), Data("b".utf8)])
        #expect(model.total == 3)

        model.openPanel(.remove)
        model.removeCountText = "10"
        #expect(model.removeDeletesKey)
        _ = await model.submitRemove()
        #expect(h.deletedCount == 1)
        #expect(try await h.run(["EXISTS", .data(key)]).intValue == 0)
    }

    // MARK: - Set

    @Test func setPagesSearchAddRemove() async throws {
        let h = try await LiveHarness.make("set")
        defer { Task { await h.cleanup() } }
        let key = h.key("s")
        try await h.run(["SADD", .data(key)] + (0..<1_100).map { .string("m\($0)") })
        let context = h.context(key, type: .set)
        let model = SetKeyViewModel(context: context)

        await model.load()
        #expect(model.total == 1_100)
        #expect(model.rows.count >= 500)
        while model.canLoadMore { await model.loadMore() }
        #expect(model.rows.count == 1_100)

        model.searchText = "m10"
        await model.applySearch()
        #expect(model.rows.map(\.member) == [Data("m10".utf8)])

        model.searchText = "m10*"
        await model.applySearch()
        while model.canLoadMore { await model.loadMore() }
        #expect(model.rows.count == 111)

        model.searchText = ""
        await model.applySearch()
        model.openAddPanel()
        model.addRows = [.init(member: "new1"), .init(member: "new1"), .init(member: "new2")]
        #expect(model.draftMembers().count == 2)
        #expect(await model.submitAdd())
        #expect(model.total == 1_102)

        await model.removeMember(Data("new1".utf8))
        #expect(model.total == 1_101)
        #expect(try await h.run(["SISMEMBER", .data(key), "new1"]).intValue == 0)
    }

    @Test func setRemovingLastMemberDeletesKey() async throws {
        let h = try await LiveHarness.make("setlast")
        defer { Task { await h.cleanup() } }
        let key = h.key("s")
        try await h.run(["SADD", .data(key), "only"])
        let model = SetKeyViewModel(context: h.context(key, type: .set))
        await model.load()
        #expect(model.isLastItem)
        await model.removeMember(Data("only".utf8))
        #expect(h.deletedCount == 1)
    }

    @Test func wrongTypeIsReportedInline() async throws {
        let h = try await LiveHarness.make("wrong")
        defer { Task { await h.cleanup() } }
        let key = h.key("s")
        try await h.run(["SET", .data(key), "v"])
        let model = SetKeyViewModel(context: h.context(key, type: .set))
        await model.load()
        #expect(model.loadError?.contains("WRONGTYPE") == true)
    }
}
