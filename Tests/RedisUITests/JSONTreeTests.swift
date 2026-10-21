import Foundation
import Testing
@testable import RedisUI

private let sample: JSONValue = .object([
    JSONMember(key: "name", value: .string("Ann")),
    JSONMember(key: "tags", value: .array([.string("a"), .number("2"), .bool(true)])),
    JSONMember(key: "meta", value: .object([JSONMember(key: "id", value: .number("12345678901234567890"))])),
    JSONMember(key: "none", value: .null),
])

@Suite("JSON tree model")
struct JSONTreeTests {
    @Test func collapsedRootShowsOneRow() {
        let rows = JSONTreeFlattener.rows(for: .value(sample), expanded: [])
        #expect(rows.count == 1)
        #expect(rows[0].kind == .container(.object, count: 4, isExpanded: false, isLoaded: true))
    }

    @Test func expandedRootListsChildrenAndClosingBracket() {
        let rows = JSONTreeFlattener.rows(for: .value(sample), expanded: [.root])
        #expect(rows.map(\.depth) == [0, 1, 1, 1, 1, 0])
        #expect(rows[1].label == .key("name"))
        #expect(rows[1].kind == .scalar(.string("Ann")))
        #expect(rows[2].kind == .container(.array, count: 3, isExpanded: false, isLoaded: true))
        #expect(rows[2].path.dotted == "$.tags")
        #expect(rows.last?.kind == .closing(.object))
    }

    @Test func nestedExpansionAndAddRows() {
        let tags = JSONPath.root.appending(key: "tags")
        let rows = JSONTreeFlattener.rows(for: .value(sample), expanded: [.root, tags], includeAddRows: true)
        let tagRows = rows.filter { $0.path.isDescendant(ofOrEqualTo: tags) }
        #expect(tagRows.map(\.path.dotted) == ["$.tags", "$.tags[0]", "$.tags[1]", "$.tags[2]", "$.tags", "$.tags"])
        #expect(tagRows[4].kind == .add(.array))
        #expect(tagRows[5].kind == .closing(.array))
        #expect(rows[rows.count - 2].kind == .add(.object))
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func pagingLargeArrays() {
        let big = JSONValue.array((0..<450).map { .number(String($0)) })
        let rows = JSONTreeFlattener.rows(for: .value(big), expanded: [.root], pageSize: 200)
        #expect(rows.count == 1 + 200 + 1 + 1)
        #expect(rows[201].kind == .more(shown: 200, remaining: 250))
        let more = JSONTreeFlattener.rows(for: .value(big), expanded: [.root], limits: [.root: 400], pageSize: 200)
        #expect(more[401].kind == .more(shown: 400, remaining: 50))
    }

    @Test func unloadedContainersShowNoChildren() {
        let root = JSONTreeNode.object([
            JSONTreeMember(key: "big", node: .unloaded(.array, count: 1000)),
            JSONTreeMember(key: "n", node: .value(.number("1"))),
        ])
        let big = JSONPath.root.appending(key: "big")
        let rows = JSONTreeFlattener.rows(for: root, expanded: [.root, big])
        #expect(rows[1].kind == .container(.array, count: 1000, isExpanded: true, isLoaded: false))
        #expect(rows[2].path.dotted == "$.n")
        #expect(root.fullValue == nil)
        #expect(root.node(at: big)?.isLoaded == false)
    }

    @Test func replacingLoadsLazyNodeAndCollapsesToValue() throws {
        let root = JSONTreeNode.object([
            JSONTreeMember(key: "list", node: .unloaded(.array, count: 2)),
            JSONTreeMember(key: "n", node: .value(.number("1"))),
        ])
        let list = JSONPath.root.appending(key: "list")
        let loaded = try #require(root.replacing(at: list, with: .array([.value(.number("1")), .value(.string("x"))])))
        #expect(loaded.fullValue == .object([
            JSONMember(key: "list", value: .array([.number("1"), .string("x")])),
            JSONMember(key: "n", value: .number("1")),
        ]))
        if case .value = loaded {} else { Issue.record("fully loaded tree should collapse to .value") }
    }

    @Test func replacingScalarInsideValue() throws {
        let path = JSONPath([.key("tags"), .index(1)])
        let updated = try #require(JSONTreeNode.value(sample).replacing(at: path, with: .value(.number("99"))))
        #expect(updated.node(at: path) == .value(.number("99")))
        #expect(JSONTreeNode.value(sample).replacing(at: JSONPath([.key("missing"), .index(0)]), with: .value(.null)) == nil)
    }

    @Test func removingAndAdding() throws {
        let tags = JSONPath.root.appending(key: "tags")
        let removed = try #require(JSONTreeNode.value(sample).removing(at: tags.appending(index: 0)))
        #expect(removed.node(at: tags)?.childCount == 2)
        #expect(removed.node(at: tags.appending(index: 0)) == .value(.number("2")))
        #expect(JSONTreeNode.value(sample).removing(at: .root) == nil)

        let appended = try #require(JSONTreeNode.value(sample).adding(.value(.string("z")), key: nil, under: tags))
        #expect(appended.node(at: tags.appending(index: 3)) == .value(.string("z")))

        let added = try #require(JSONTreeNode.value(sample).adding(.value(.bool(false)), key: "flag", under: .root))
        #expect(added.childCount == 5)
        let overwritten = try #require(JSONTreeNode.value(sample).adding(.value(.string("Bob")), key: "name", under: .root))
        #expect(overwritten.childCount == 4)
        #expect(overwritten.node(at: JSONPath([.key("name")])) == .value(.string("Bob")))
    }

    @MainActor @Test func modelKeepsExpansionAcrossReloads() {
        let model = JSONTreeModel(value: sample)
        let meta = JSONPath.root.appending(key: "meta")
        model.setExpanded(meta, true)
        model.setValue(sample)
        #expect(model.isExpanded(meta))
        model.setValue(sample, resetExpansion: true)
        #expect(!model.isExpanded(meta))
        #expect(model.isExpanded(.root))
    }

    @MainActor @Test func modelExpandAllAndRemove() {
        let model = JSONTreeModel(value: sample)
        model.expandAll()
        #expect(model.expanded == [.root, JSONPath([.key("tags")]), JSONPath([.key("meta")])])
        model.selectedPath = JSONPath([.key("meta"), .key("id")])
        model.removeNode(at: JSONPath([.key("meta")]))
        #expect(model.selectedPath == nil)
        #expect(!model.expanded.contains(JSONPath([.key("meta")])))
        #expect(model.root.childCount == 3)
        model.collapseAll()
        #expect(model.expanded == [.root])
    }

    @MainActor @Test func modelShowMore() {
        let model = JSONTreeModel(root: .value(.array((0..<10).map { .number(String($0)) })), pageSize: 4)
        #expect(model.rows(includeAddRows: false).count == 1 + 4 + 1 + 1)
        model.showMore(at: .root)
        #expect(model.rows(includeAddRows: false).count == 1 + 8 + 1 + 1)
    }
}

@MainActor
private final class WriteLog {
    var writes: [String] = []
}

@MainActor
@Suite("JSON tree editing")
struct JSONTreeEditingTests {
    private let meta = JSONPath([.key("meta")])

    private func operations(_ log: WriteLog) -> JSONTreeOperations {
        JSONTreeOperations(model: JSONTreeModel(value: sample),
                           actions: JSONTreeActions(setValue: { _, text in log.writes.append(text) }),
                           edit: JSONTreeEditState())
    }

    @Test func containerEditorStartsWithSaveEnabled() {
        let ops = operations(WriteLog())
        ops.beginEdit(meta)
        #expect(ops.edit.containerSheet?.path == meta)
        #expect(ops.edit.editValidity.accepts(ops.edit.editText))
        ops.edit.editText += ","
        #expect(!ops.edit.editValidity.accepts(ops.edit.editText))
    }

    @Test func duplicateKeysWaitForOverwrite() async throws {
        let log = WriteLog()
        let ops = operations(log)
        let edited = #"{"id": 1, "id": 2}"#
        ops.beginEdit(meta)
        ops.edit.editText = edited
        await ops.saveEdit(at: meta)?.value
        let prompt = try #require(ops.edit.duplicateKeys)
        #expect(prompt.keys == ["id"])
        #expect(ops.edit.busy)
        #expect(log.writes.isEmpty)

        #expect(ops.resolveDuplicateKeys(prompt, overwrite: false) == nil)
        #expect(ops.edit.duplicateKeys == nil)
        #expect(!ops.edit.busy)
        #expect(ops.edit.containerSheet?.path == meta)
        #expect(log.writes.isEmpty)

        await ops.saveEdit(at: meta)?.value
        let again = try #require(ops.edit.duplicateKeys)
        #expect(ops.resolveDuplicateKeys(prompt, overwrite: true) == nil)
        await ops.resolveDuplicateKeys(again, overwrite: true)?.value
        #expect(log.writes == [edited])
        #expect(ops.edit.containerSheet == nil)
        #expect(ops.model.node(at: meta) == .value(.object([
            JSONMember(key: "id", value: .number("1")), JSONMember(key: "id", value: .number("2")),
        ])))
    }

    @Test func uniqueKeysSaveWithoutPrompt() async {
        let log = WriteLog()
        let ops = operations(log)
        ops.beginEdit(meta)
        ops.edit.editText = #"{"id": 7}"#
        await ops.saveEdit(at: meta)?.value
        #expect(ops.edit.duplicateKeys == nil)
        #expect(log.writes == [#"{"id": 7}"#])
        #expect(ops.edit.containerSheet == nil)
    }

    @Test func invalidTextShowsErrorWithoutWriting() async {
        let log = WriteLog()
        let ops = operations(log)
        ops.beginEdit(meta)
        ops.edit.editText = "{oops"
        await ops.saveEdit(at: meta)?.value
        #expect(ops.edit.error == "Enter valid JSON.")
        #expect(!ops.edit.busy)
        #expect(log.writes.isEmpty)
    }

    @Test func cancellingDuringTheParseDropsTheSave() async {
        let log = WriteLog()
        let ops = operations(log)
        ops.beginEdit(meta)
        ops.edit.editText = #"{"id": 7}"#
        let save = ops.saveEdit(at: meta)
        ops.edit.cancel()
        await save?.value
        #expect(log.writes.isEmpty)
        #expect(ops.edit.error == nil)
    }

    @Test func validityCheckRunsAfterThePause() async {
        #expect(await JSONTextValidity.check(#"{"a": 1}"#, after: .zero) == JSONTextValidity(text: #"{"a": 1}"#, isValid: true))
        #expect(await JSONTextValidity.check("{oops", after: .zero) == JSONTextValidity(text: "{oops", isValid: false))
        let pending = Task { await JSONTextValidity.check("[1]", after: .seconds(30)) }
        pending.cancel()
        #expect(await pending.value == nil)
    }
}

@Suite("JSON literals")
struct JSONLiteralTests {
    @Test func scalarFormatting() {
        #expect(JSONLiteral.format(.string("a\"b\\c\n\t\u{01}")) == #""a\"b\\c\n\t\u0001""#)
        #expect(JSONLiteral.format(.number("12345678901234567890")) == "12345678901234567890")
        #expect(JSONLiteral.format(.bool(false)) == "false")
        #expect(JSONLiteral.format(.null) == "null")
        #expect(JSONLiteral.format(.array([.number("1"), .object([])])) == "[1,{}]")
    }

    @Test func prettyPrinting() {
        let value: JSONValue = .object([
            JSONMember(key: "a", value: .array([.number("1"), .number("1e-7")])),
            JSONMember(key: "b", value: .object([])),
        ])
        #expect(JSONLiteral.pretty(value, indent: 2) == "{\n  \"a\": [\n    1,\n    1e-7\n  ],\n  \"b\": {}\n}")
        #expect(JSONLiteral.pretty(.array([]), indent: 4) == "[]")
    }

    @Test func collapsedPreview() {
        #expect(JSONLiteral.collapsedPreview(.object, count: 0) == "{}")
        #expect(JSONLiteral.collapsedPreview(.array, count: 3) == "[…]")
    }

    @Test func quotedKeyRule() {
        #expect(JSONLiteral.parseQuotedKey(#""name""#) == "name")
        #expect(JSONLiteral.parseQuotedKey(#" "a\"b" "#) == #"a"b"#)
        #expect(JSONLiteral.parseQuotedKey("name") == nil)
        #expect(JSONLiteral.parseQuotedKey("\"") == nil)
    }

    @Test func parsingUsesSharedParser() {
        #expect(JSONLiteral.parse(#"{"a": [1, true]}"#) == .object([JSONMember(key: "a", value: .array([.number("1"), .bool(true)]))]))
        #expect(JSONLiteral.parse("{oops") == nil)
    }
}
