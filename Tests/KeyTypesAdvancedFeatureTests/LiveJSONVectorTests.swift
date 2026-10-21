import Foundation
@testable import KeyTypesAdvancedFeature
import RedisCore
import RedisUI
import TestSupport
import Testing

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis, modules: .json))
struct LiveJSONTests {
    @Test func smallDocumentLoadsFullyAndEdits() async throws {
        let h = try await LiveHarness.make("json")
        defer { Task { await h.cleanup() } }
        let key = h.key("doc")
        try await h.run(["JSON.SET", .data(key), "$", #"{"name":"bike","price":10,"big":12345678901234567890,"tags":["a"]}"#])
        let model = JSONKeyViewModel(context: h.context(key, type: .json))
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.isFullyLoaded)
        #expect(model.rootType == .object)
        #expect(model.tree.root.childCount == 4)
        let full = try #require(model.tree.root.fullValue)
        #expect(JSONLiteral.format(full).contains("12345678901234567890"))

        let actions = model.actions
        try await actions.setValue?(JSONPath.root.appending(key: "price"), "25")
        #expect(try await h.run(["JSON.GET", .data(key), "$.price"]).stringValue == "[25]")

        try await actions.addEntry?(.root, "color", #""red""#)
        #expect(try await h.run(["JSON.GET", .data(key), "$.color"]).stringValue == #"["red"]"#)

        try await actions.addEntry?(JSONPath.root.appending(key: "tags"), nil, #""b""#)
        #expect(try await h.run(["JSON.GET", .data(key), "$.tags"]).stringValue == #"[["a","b"]]"#)

        try await actions.delete?(JSONPath.root.appending(key: "name"))
        #expect(try await h.run(["JSON.GET", .data(key), "$.name"]).stringValue == "[]")

        try await actions.setValue?(.root, #"{"replaced":true}"#)
        #expect(try await h.run(["JSON.GET", .data(key), "$"]).stringValue == #"[{"replaced":true}]"#)
        #expect(h.changedCount >= 5)
    }

    @Test func bigDocumentLoadsLazily() async throws {
        let h = try await LiveHarness.make("jsonbig")
        defer { Task { await h.cleanup() } }
        let key = h.key("doc")
        let members = (0..<250).map { #""k\#($0)":{"index":\#($0),"label":"value number \#($0)"}"# }
        try await h.run(["JSON.SET", .data(key), "$", .string("{" + members.joined(separator: ",") + "}")])

        let model = JSONKeyViewModel(context: h.context(key, type: .json))
        await model.load()
        #expect(!model.isFullyLoaded)
        #expect(model.tree.root.childCount == 250)
        let child = JSONPath.root.appending(key: "k7")
        let node = try #require(model.tree.node(at: child))
        #expect(!node.isLoaded)
        #expect(node.childCount == 2)

        let loaded = try #require(try await model.actions.loadChildren?(child))
        #expect(loaded.isLoaded)
        #expect(loaded.childCount == 2)
    }

    @Test func quotedKeysAndMissingKey() async throws {
        let h = try await LiveHarness.make("jsonq")
        defer { Task { await h.cleanup() } }
        let key = h.key("doc")
        try await h.run(["JSON.SET", .data(key), "$", #"{"a\"b":1,"sp ace":2}"#])
        let model = JSONKeyViewModel(context: h.context(key, type: .json))
        await model.load()
        try await model.actions.setValue?(JSONPath.root.appending(key: "a\"b"), "5")
        try await model.actions.setValue?(JSONPath.root.appending(key: "sp ace"), "6")
        #expect(try await h.run(["JSON.GET", .data(key), "$"]).stringValue == #"[{"a\"b":5,"sp ace":6}]"#)

        let missing = JSONKeyViewModel(context: h.context(h.key("missing"), type: .json))
        await missing.load()
        #expect(h.deletedCount == 1)
    }
}

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis, modules: .vectorSet))
struct LiveVectorSetTests {
    private func seed(_ h: LiveHarness, key: Data, count: Int) async throws {
        var commands: [[RedisArgument]] = []
        for i in 0..<count {
            let attrs = #"{"price":\#(i),"category":"\#(i.isMultiple(of: 2) ? "even" : "odd")"}"#
            commands.append(["VADD", .data(key), "VALUES", "3", .string(String(Double(i) / 10)), "0.5", "1",
                             .string("e\(String(format: "%02d", i))"), "SETATTR", .string(attrs)])
        }

        try await h.pipeline(commands)
    }

    @Test func listsPagesAndAttributes() async throws {
        let h = try await LiveHarness.make("vlist")
        defer { Task { await h.cleanup() } }
        let key = h.key("v")
        try await seed(h, key: key, count: 120)
        let model = VectorSetViewModel(context: h.context(key, type: .vectorSet))
        await model.load()
        #expect(model.total == 120)
        #expect(model.info.dimension == 3)
        #expect(model.rows.count == VectorSetCommands.pageSize)
        #expect(model.isPaginationSupported)
        #expect(model.canLoadMore)
        #expect(model.knownAttributeKeys == ["category", "price"])
        #expect(model.rows.allSatisfy { $0.attributes != nil })
        #expect(model.listStatusText == "Showing 50 of 120")
        let firstPage = Set(model.rows.map(\.name))

        await model.loadNextPage()
        #expect(model.rows.count == 100)
        #expect(Set(model.rows.suffix(50).map(\.name)).isDisjoint(with: firstPage))
        await model.loadNextPage()
        #expect(model.rows.count == 120)
        #expect(Set(model.rows.map(\.name)).count == 120)
        #expect(!model.canLoadMore)

        await model.refresh()
        #expect(model.rows.count == 120)
    }

    @Test func removeKeepsTotalAndPagingInStep() async throws {
        let h = try await LiveHarness.make("vremove")
        defer { Task { await h.cleanup() } }
        let key = h.key("v")
        try await seed(h, key: key, count: 70)
        let model = VectorSetViewModel(context: h.context(key, type: .vectorSet))
        await model.load()
        #expect(model.rows.count == VectorSetCommands.pageSize)
        let removed = try #require(model.rows.first?.name)

        await model.remove(removed)
        #expect(model.total == 69)
        #expect(model.rows.count == VectorSetCommands.pageSize - 1)
        #expect(!model.rows.contains { $0.name == removed })
        #expect(model.listStatusText == "Showing 49 of 69")
        #expect(h.changedCount == 1)

        await model.loadNextPage()
        #expect(model.rows.count == 69)
        #expect(Set(model.rows.map(\.name)).count == 69)
        #expect(model.total == 69)
        #expect(!model.canLoadMore)
    }

    @Test func detailsAttributesAndSimilarity() async throws {
        let h = try await LiveHarness.make("vsim")
        defer { Task { await h.cleanup() } }
        let key = h.key("v")
        try await seed(h, key: key, count: 12)
        let model = VectorSetViewModel(context: h.context(key, type: .vectorSet))
        await model.load()

        await model.openDetails(Data("e03".utf8))
        let details = try #require(model.details)
        #expect(details.vectorValues.count == 3)
        #expect(details.attributes.contains("price"))

        model.updateDraftAttributes(#"{"price":999}"#)
        #expect(model.details?.isEditingAttributes == true)
        await model.saveAttributes()
        #expect(model.details?.isEditingAttributes == false)
        #expect(try await h.run(["VGETATTR", .data(key), "e03"]).stringValue == #"{"price":999}"#)

        model.mode = .element
        model.queryText = "e00"
        model.resultCount = 5
        let request = try #require(model.request)
        #expect(request.count == 5)
        await model.search()
        let results = try #require(model.results)
        #expect(results.count == 5)
        #expect(results.first?.rank == 1)
        #expect(results.allSatisfy { $0.attributes != nil })
        #expect(model.commandPreview?.hasPrefix("VSIM ") == true)

        model.mode = .vector
        model.queryText = "0.1 0.5 1"
        model.filter = ".category == \"odd\""
        await model.search()
        let filtered = try #require(model.results)
        #expect(!filtered.isEmpty)
        #expect(filtered.allSatisfy { ($0.attributes ?? "").contains("odd") })

        model.queryText = "1 2"
        #expect(model.queryError == "This vector has 2 values, but the set expects 3")
        #expect(model.request == nil)

        model.sort(by: .element)
        #expect(model.resultSortAscending)
        model.clearResults()
        #expect(model.results == nil)

        model.findSimilar(to: Data("e05".utf8))
        #expect(model.mode == .element)
        #expect(model.queryText == "e05")
    }

    @Test func addAndRemoveElements() async throws {
        let h = try await LiveHarness.make("vadd")
        defer { Task { await h.cleanup() } }
        let key = h.key("v")
        try await h.run(["VADD", .data(key), "VALUES", "2", "1", "0", "a", "NOQUANT"])
        let model = VectorSetViewModel(context: h.context(key, type: .vectorSet))
        await model.load()
        #expect(model.info.quantType == "f32")

        model.openAddPanel()
        model.drafts = [VectorElementInput(name: "b", vector: "0 1"),
                        VectorElementInput(name: "c", vector: "\\x00\\x00\\x80\\x3f\\x00\\x00\\x00\\x00", attributes: #"{"x":1}"#)]
        #expect(model.isAddValid)
        await model.saveDrafts()
        #expect(!model.isAddPanelOpen)
        #expect(model.total == 3)
        #expect(try await h.run(["VGETATTR", .data(key), "c"]).stringValue == #"{"x":1}"#)

        model.drafts = [VectorElementInput(name: "d", vector: "1 2 3")]
        #expect(!model.isAddValid)

        await model.remove(Data("b".utf8))
        #expect(model.total == 2)
        await model.remove(Data("c".utf8))
        await model.remove(Data("a".utf8))
        #expect(h.deletedCount == 1)
        #expect(try await h.exists(key) == false)
    }

    @Test func addKeyFormCreatesVectorSet() async throws {
        let h = try await LiveHarness.make("vform")
        defer { Task { await h.cleanup() } }
        let key = h.key("new")
        let model = VectorSetAddKeyModel(context: h.addKeyContext(name: key, ttl: 600))
        model.drafts = [VectorElementInput(name: "one", vector: "1 2 3 4"),
                        VectorElementInput(name: "two", vector: "4 3 2 1", attributes: #"{"tag":"x"}"#)]
        model.quantization = .noQuant
        model.reduceText = "2"
        #expect(model.isValid)
        #expect(model.previewText.hasPrefix("VADD "))
        #expect(await model.submit())
        #expect(h.addedKeys == [key])
        #expect(try await h.run(["VCARD", .data(key)]).intValue == 2)
        let ttl = try await h.run(["TTL", .data(key)]).intValue ?? 0
        #expect(ttl > 590)
        let info = VectorSetCommands.parseInfo(try await h.run(["VINFO", .data(key)]))
        #expect(info.quantType == "f32")
        #expect(info.dimension == 2)
        #expect(info.inputDimension == 4)

        let again = VectorSetAddKeyModel(context: h.addKeyContext(name: key))
        again.drafts = [VectorElementInput(name: "x", vector: "1 2 3 4")]
        #expect(await again.submit() == false)
        #expect(again.errorMessage == "This key name is already in use.")

        let invalid = VectorSetAddKeyModel(context: h.addKeyContext(name: h.key("bad")))
        invalid.drafts = [VectorElementInput(name: "x", vector: "1 2"), VectorElementInput(name: "y", vector: "1 2 3")]
        #expect(!invalid.isValid)
        #expect(invalid.validationMessage == "This vector has 3 values, but the set expects 2")
    }

    @Test func addKeyFormLeavesAnExistingKeyOfAnotherTypeUntouched() async throws {
        let h = try await LiveHarness.make("vtaken")
        defer { Task { await h.cleanup() } }
        let key = h.key("taken")
        try await h.run(["SET", .data(key), "keep", "EX", "1000"])
        let model = VectorSetAddKeyModel(context: h.addKeyContext(name: key, ttl: 5))
        model.drafts = [VectorElementInput(name: "x", vector: "1 2")]
        #expect(await model.submit() == false)
        #expect(model.errorMessage == "This key name is already in use.")
        #expect(h.addedKeys.isEmpty)
        #expect(try await h.run(["GET", .data(key)]).stringValue == "keep")
        #expect((try await h.run(["TTL", .data(key)]).intValue ?? 0) > 900)
    }
}
