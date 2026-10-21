import Foundation
import Testing
@testable import RedisUI

@MainActor
@Suite("JSON tree paging")
struct JSONTreePagingTests {
    private func pagedArray(fetched: Int, total: Int) -> JSONTreeNode {
        .array((0..<fetched).map { .value(.number(String($0))) } + Array(repeating: .pending, count: total - fetched))
    }

    private func waitUntilIdle(_ model: JSONTreeModel) async {
        for _ in 0..<200 where !model.loading.isEmpty { await Task.yield() }
    }

    @Test func pendingChildrenAreNeverShown() {
        let model = JSONTreeModel(root: pagedArray(fetched: 2, total: 5), pageSize: 4)
        let rows = model.rows(includeAddRows: false)
        #expect(rows.filter { if case .scalar = $0.kind { true } else { false } }.count == 2)
        #expect(rows.contains { $0.kind == .more(shown: 4, remaining: 1) })
        #expect(model.root.fetchedChildCount == 2)
        #expect(!model.root.isFullyLoaded)
    }

    @Test func showMoreFetchesPendingChildrenBeforeRevealing() async {
        let model = JSONTreeModel(root: pagedArray(fetched: 2, total: 5), pageSize: 2)
        var requested: [[JSONPath]] = []
        let actions = JSONTreeActions(loadChildPage: { paths in
            requested.append(paths)
            return paths.map { .value(.string($0.dotted)) }
        })
        let operations = JSONTreeOperations(model: model, actions: actions, edit: JSONTreeEditState())
        operations.showMore(.root)
        await waitUntilIdle(model)
        #expect(requested == [[JSONPath.root.appending(index: 2), JSONPath.root.appending(index: 3)]])
        #expect(model.visibleChildLimit(at: .root) == 4)
        #expect(model.root.fetchedChildCount == 4)
        #expect(model.root.node(at: JSONPath.root.appending(index: 3)) == .value(.string("$[3]")))

        operations.showMore(.root)
        await waitUntilIdle(model)
        #expect(model.root.isFullyLoaded)
        #expect(model.root.fullValue != nil)
    }

    @Test func showMoreWithoutLoaderOnlyRaisesTheLimit() {
        let model = JSONTreeModel(root: .value(.array((0..<6).map { .number(String($0)) })), pageSize: 2)
        let operations = JSONTreeOperations(model: model, actions: .readOnly, edit: JSONTreeEditState())
        operations.showMore(.root)
        #expect(model.visibleChildLimit(at: .root) == 4)
    }
}
