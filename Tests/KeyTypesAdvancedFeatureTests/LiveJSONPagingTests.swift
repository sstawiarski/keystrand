import Foundation
@testable import KeyTypesAdvancedFeature
import RedisCore
import RedisUI
import TestSupport
import Testing

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis, modules: .json))
struct LiveJSONPagingTests {
    @Test func largeArraySummarizesOnlyTheFirstPage() async throws {
        let h = try await LiveHarness.make("jsonpage")
        defer { Task { await h.cleanup() } }
        let key = h.key("arr")
        let items = (0..<500).map { #"{"i":\#($0),"pad":"\#(String(repeating: "x", count: 20))"}"# }
        try await h.run(["JSON.SET", .data(key), "$", .string("[" + items.joined(separator: ",") + "]")])

        let model = JSONKeyViewModel(context: h.context(key, type: .json))
        await model.load()
        let root = model.tree.root
        #expect(root.childCount == 500)
        #expect(root.fetchedChildCount == JSONTreeFlattener.defaultPageSize)
        #expect(root.node(at: JSONPath.root.appending(index: 199)) == .unloaded(.object, count: 2))
        #expect(root.node(at: JSONPath.root.appending(index: 200)) == .pending)
        #expect(!model.tree.rows(includeAddRows: false).contains { $0.path == JSONPath.root.appending(index: 200) })

        let paths = (200..<400).map { JSONPath.root.appending(index: $0) }
        let page = try #require(try await model.actions.loadChildPage?(paths))
        #expect(page.count == 200)
        #expect(page.allSatisfy { $0 == .unloaded(.object, count: 2) })
        model.tree.replaceChildren(at: .root, from: 200, with: page)
        model.tree.showMore(at: .root)
        #expect(model.tree.root.fetchedChildCount == 400)
        #expect(model.tree.rows(includeAddRows: false).contains { $0.path == JSONPath.root.appending(index: 399) })
    }

    @Test func largeObjectKeepsEveryKeyButSummarizesOnePage() async throws {
        let h = try await LiveHarness.make("jsonpageobj")
        defer { Task { await h.cleanup() } }
        let key = h.key("obj")
        let members = (0..<300).map { #""k\#($0)":"\#(String(repeating: "v", count: 20))""# }
        try await h.run(["JSON.SET", .data(key), "$", .string("{" + members.joined(separator: ",") + "}")])

        let model = JSONKeyViewModel(context: h.context(key, type: .json))
        await model.load()
        guard case .object(let loaded) = model.tree.root else {
            Issue.record("Expected a lazily loaded object")
            return
        }
        #expect(loaded.count == 300)
        #expect(loaded.prefix(200).allSatisfy { $0.node != .pending })
        #expect(loaded.dropFirst(200).allSatisfy { $0.node == .pending })
        #expect(model.tree.root.fullValue == nil)
    }
}
