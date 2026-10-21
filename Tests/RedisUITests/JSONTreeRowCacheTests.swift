import Foundation
import Observation
import Synchronization
import Testing
@testable import RedisUI

@MainActor
@Suite("JSON tree row cache")
struct JSONTreeRowCacheTests {
    private let document: JSONValue = .object([
        JSONMember(key: "a", value: .number("1")),
        JSONMember(key: "b", value: .array([.number("2"), .number("3")])),
    ])

    @Test func rowsFollowExpansionRootAndLimitChanges() {
        let model = JSONTreeModel(value: document)
        #expect(model.rows(includeAddRows: false).count == 4)
        model.setExpanded(JSONPath([.key("b")]), true)
        #expect(model.rows(includeAddRows: false).count == 7)
        #expect(model.rows(includeAddRows: true).count == 9)
        model.setValue(.array([.null]))
        #expect(model.rows(includeAddRows: false).map(\.kind) == [
            .container(.array, count: 1, isExpanded: true, isLoaded: true), .scalar(.null), .closing(.array),
        ])
        model.pageSize = 1
        model.setValue(.array([.null, .null, .null]))
        #expect(model.rows(includeAddRows: false).count == 4)
        model.showMore(at: .root)
        #expect(model.rows(includeAddRows: false).count == 5)
    }

    @Test func nodePathsIndexVisibleNodes() {
        let model = JSONTreeModel(value: document)
        model.setExpanded(JSONPath([.key("b")]), true)
        let nodes = model.nodePaths()
        #expect(nodes.paths == [.root, JSONPath([.key("a")]), JSONPath([.key("b")]),
                                JSONPath([.key("b"), .index(0)]), JSONPath([.key("b"), .index(1)])])
        #expect(nodes.positions[JSONPath([.key("b"), .index(1)])] == 4)
        #expect(JSONTreeNavigation.move(from: JSONPath([.key("a")]), offset: 1, in: nodes) == JSONPath([.key("b")]))
        model.setExpanded(JSONPath([.key("b")]), false)
        #expect(model.nodePaths().paths.count == 3)
    }

    @Test func cachedRowsStillTrackObservation() {
        let model = JSONTreeModel(value: document)
        _ = model.rows(includeAddRows: false)
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.rows(includeAddRows: false)
        } onChange: {
            changed.withLock { $0 = true }
        }
        model.setExpanded(JSONPath([.key("b")]), true)
        #expect(changed.withLock { $0 })
    }

    @Test func selectionDoesNotInvalidateRows() {
        let model = JSONTreeModel(value: document)
        _ = model.rows(includeAddRows: false)
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.rows(includeAddRows: false)
        } onChange: {
            changed.withLock { $0 = true }
        }
        model.selectedPath = JSONPath([.key("a")])
        #expect(!changed.withLock { $0 })
    }

    @Test func rowIDsDistinguishLinesOfOneContainer() {
        let rows = JSONTreeFlattener.rows(for: .value(document), expanded: [.root], includeAddRows: true)
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows.first?.id == .node(.root))
    }

    @Test func fullyLoadedCheckMatchesFullValue() {
        let partial: JSONTreeNode = .object([JSONTreeMember(key: "x", node: .unloaded(.array, count: 3))])
        #expect(!partial.isFullyLoaded)
        #expect(partial.fullValue == nil)
        let loaded: JSONTreeNode = .array([.value(.null)])
        #expect(loaded.isFullyLoaded)
    }
}
