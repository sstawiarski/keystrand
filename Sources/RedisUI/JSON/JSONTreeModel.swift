import Foundation
import Observation

public enum JSONContainerKind: String, Hashable, Sendable {
    case object
    case array

    public var open: String { self == .object ? "{" : "[" }
    public var close: String { self == .object ? "}" : "]" }
}

public struct JSONTreeMember: Hashable, Sendable {
    public var key: String
    public var node: JSONTreeNode

    public init(key: String, node: JSONTreeNode) {
        self.key = key
        self.node = node
    }
}

/// JSON document with partially loaded subtrees.
public indirect enum JSONTreeNode: Hashable, Sendable {
    /// Fully known subtree (scalar or container).
    case value(JSONValue)
    /// Object whose members may include unloaded containers.
    case object([JSONTreeMember])
    /// Array whose elements may include unloaded containers.
    case array([JSONTreeNode])
    /// Container whose children have not been fetched; `count` is its cardinality.
    case unloaded(JSONContainerKind, count: Int)
    /// Child of a large container beyond the pages fetched so far; its type and value are unknown.
    case pending

    public var containerKind: JSONContainerKind? {
        switch self {
        case .value(.object), .object, .unloaded(.object, _): return .object
        case .value(.array), .array, .unloaded(.array, _): return .array
        default: return nil
        }
    }

    public var isContainer: Bool { containerKind != nil }

    public var isLoaded: Bool {
        switch self {
        case .unloaded, .pending: return false
        default: return true
        }
    }

    public var childCount: Int {
        switch self {
        case .value(.object(let members)): return members.count
        case .value(.array(let items)): return items.count
        case .value: return 0
        case .object(let members): return members.count
        case .array(let items): return items.count
        case .unloaded(_, let count): return count
        case .pending: return 0
        }
    }

    /// Number of leading children that are fetched (all of them unless the container is paged).
    public var fetchedChildCount: Int {
        switch self {
        case .object(let members): return members.firstIndex { $0.node == .pending } ?? members.count
        case .array(let items): return items.firstIndex(of: .pending) ?? items.count
        default: return childCount
        }
    }

    /// The scalar value, or nil for containers.
    public var scalar: JSONValue? {
        switch self {
        case .value(.object), .value(.array): return nil
        case .value(let value): return value
        default: return nil
        }
    }

    /// Children `range` of a loaded container, as (component, node) pairs.
    public func children(in range: Range<Int>) -> [(JSONPathComponent, JSONTreeNode)] {
        let clamped = range.clamped(to: 0..<childCount)
        switch self {
        case .value(.object(let members)):
            return members[clamped].map { (.key($0.key), .value($0.value)) }
        case .value(.array(let items)):
            return clamped.map { (.index($0), .value(items[$0])) }
        case .object(let members):
            return members[clamped].map { (.key($0.key), $0.node) }
        case .array(let items):
            return clamped.map { (.index($0), items[$0]) }
        default:
            return []
        }
    }

    public func child(_ component: JSONPathComponent) -> JSONTreeNode? {
        switch (self, component) {
        case (.value(.object(let members)), .key(let key)):
            return members.last { $0.key == key }.map { .value($0.value) }
        case (.value(.array(let items)), .index(let index)):
            return items.indices.contains(index) ? .value(items[index]) : nil
        case (.object(let members), .key(let key)):
            return members.last { $0.key == key }?.node
        case (.array(let items), .index(let index)):
            return items.indices.contains(index) ? items[index] : nil
        default:
            return nil
        }
    }

    public func node(at path: JSONPath) -> JSONTreeNode? {
        var current: JSONTreeNode? = self
        for component in path.components {
            current = current?.child(component)
        }

        return current
    }

    /// Whether no descendant is unloaded, so `fullValue` is non-nil; does not build the value.
    public var isFullyLoaded: Bool {
        switch self {
        case .value: return true
        case .unloaded, .pending: return false
        case .object(let members): return members.allSatisfy(\.node.isFullyLoaded)
        case .array(let items): return items.allSatisfy(\.isFullyLoaded)
        }
    }

    /// The whole subtree as a `JSONValue`, or nil when any descendant is unloaded.
    public var fullValue: JSONValue? {
        switch self {
        case .value(let value): return value
        case .unloaded, .pending: return nil
        case .object(let members):
            var result: [JSONMember] = []
            result.reserveCapacity(members.count)
            for member in members {
                guard let value = member.node.fullValue else { return nil }
                result.append(JSONMember(key: member.key, value: value))
            }

            return .object(result)
        case .array(let items):
            var result: [JSONValue] = []
            result.reserveCapacity(items.count)
            for item in items {
                guard let value = item.fullValue else { return nil }
                result.append(value)
            }

            return .array(result)
        }
    }

    /// Returns a copy with the node at `path` replaced (nil when the path does not exist).
    public func replacing(at path: JSONPath, with replacement: JSONTreeNode) -> JSONTreeNode? {
        guard let first = path.components.first else { return replacement }
        let rest = JSONPath(Array(path.components.dropFirst()))
        switch (self.expandedOneLevel, first) {
        case (.object(var members), .key(let key)):
            guard let index = members.lastIndex(where: { $0.key == key }),
                  let updated = members[index].node.replacing(at: rest, with: replacement) else { return nil }
            members[index].node = updated
            return JSONTreeNode.object(members).collapsedIfLoaded
        case (.array(var items), .index(let index)):
            guard items.indices.contains(index), let updated = items[index].replacing(at: rest, with: replacement) else { return nil }
            items[index] = updated
            return JSONTreeNode.array(items).collapsedIfLoaded
        default:
            return nil
        }
    }

    /// Returns a copy without the node at `path` (nil when it does not exist or is the root).
    public func removing(at path: JSONPath) -> JSONTreeNode? {
        guard let parentPath = path.parent, let last = path.last, let parent = node(at: parentPath) else { return nil }
        let updatedParent: JSONTreeNode
        switch (parent.expandedOneLevel, last) {
        case (.object(var members), .key(let key)):
            guard let index = members.lastIndex(where: { $0.key == key }) else { return nil }
            members.remove(at: index)
            updatedParent = JSONTreeNode.object(members).collapsedIfLoaded
        case (.array(var items), .index(let index)):
            guard items.indices.contains(index) else { return nil }
            items.remove(at: index)
            updatedParent = JSONTreeNode.array(items).collapsedIfLoaded
        default:
            return nil
        }

        return replacing(at: parentPath, with: updatedParent)
    }

    /// Adds `node` under the container at `parentPath` (object: sets `key`, array: appends).
    public func adding(_ node: JSONTreeNode, key: String?, under parentPath: JSONPath) -> JSONTreeNode? {
        guard let parent = self.node(at: parentPath) else { return nil }
        let updatedParent: JSONTreeNode
        switch parent.expandedOneLevel {
        case .object(var members):
            guard let key else { return nil }
            if let index = members.lastIndex(where: { $0.key == key }) {
                members[index].node = node
            } else {
                members.append(JSONTreeMember(key: key, node: node))
            }

            updatedParent = JSONTreeNode.object(members).collapsedIfLoaded
        case .array(var items):
            items.append(node)
            updatedParent = JSONTreeNode.array(items).collapsedIfLoaded
        default:
            return nil
        }

        return replacing(at: parentPath, with: updatedParent)
    }

    /// `.value(container)` expressed as `.object` / `.array` of child nodes.
    var expandedOneLevel: JSONTreeNode {
        switch self {
        case .value(.object(let members)): return .object(members.map { JSONTreeMember(key: $0.key, node: .value($0.value)) })
        case .value(.array(let items)): return .array(items.map { .value($0) })
        default: return self
        }
    }

    /// Back to `.value` when every child is loaded.
    var collapsedIfLoaded: JSONTreeNode {
        if case .value = self { return self }
        if let value = fullValue { return .value(value) }
        return self
    }
}

/// One visible line of the tree.
public struct JSONTreeRow: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Container opening line (`"key": {` when expanded, `"key": {…}` when collapsed).
        case container(JSONContainerKind, count: Int, isExpanded: Bool, isLoaded: Bool)
        case scalar(JSONValue)
        /// Closing bracket of an expanded container.
        case closing(JSONContainerKind)
        /// "Show more" placeholder after `shown` children of a large container.
        case more(shown: Int, remaining: Int)
        /// "+" add row inside an expanded container.
        case add(JSONContainerKind)
    }

    /// Row identity: the node or container path plus which line of it this is.
    public struct ID: Hashable, Sendable {
        public enum Role: Hashable, Sendable { case node, closing, more, add }
        public var role: Role
        public var path: JSONPath

        public static func node(_ path: JSONPath) -> ID { ID(role: .node, path: path) }
    }

    public let kind: Kind
    /// For `.closing`, `.more` and `.add` this is the container's path.
    public let path: JSONPath
    public var depth: Int
    public var label: JSONPathComponent?
    public let id: ID

    public init(kind: Kind, path: JSONPath, depth: Int, label: JSONPathComponent?) {
        self.kind = kind
        self.path = path
        self.depth = depth
        self.label = label
        let role: ID.Role
        switch kind {
        case .container, .scalar: role = .node
        case .closing: role = .closing
        case .more: role = .more
        case .add: role = .add
        }

        self.id = ID(role: role, path: path)
    }
}

public enum JSONTreeFlattener {
    public static let defaultPageSize = 200

    /// Visible rows for `root` given expanded paths and per-container visible-child limits.
    public static func rows(for root: JSONTreeNode, expanded: Set<JSONPath>, limits: [JSONPath: Int] = [:],
                            pageSize: Int = defaultPageSize, includeAddRows: Bool = false) -> [JSONTreeRow] {
        var rows: [JSONTreeRow] = []
        visit(root, path: .root, depth: 0, label: nil, expanded: expanded, limits: limits, pageSize: pageSize,
              includeAddRows: includeAddRows, rows: &rows)
        return rows
    }

    private static func visit(_ node: JSONTreeNode, path: JSONPath, depth: Int, label: JSONPathComponent?,
                              expanded: Set<JSONPath>, limits: [JSONPath: Int], pageSize: Int,
                              includeAddRows: Bool, rows: inout [JSONTreeRow]) {
        guard let kind = node.containerKind else {
            rows.append(JSONTreeRow(kind: .scalar(node.scalar ?? .null), path: path, depth: depth, label: label))
            return
        }
        let count = node.childCount
        let isExpanded = expanded.contains(path)
        rows.append(JSONTreeRow(kind: .container(kind, count: count, isExpanded: isExpanded, isLoaded: node.isLoaded),
                                path: path, depth: depth, label: label))
        guard isExpanded, node.isLoaded else { return }
        let limit = min(count, max(limits[path] ?? pageSize, 1))
        for (component, child) in node.children(in: 0..<limit) where child != .pending {
            visit(child, path: path.appending(component), depth: depth + 1, label: component, expanded: expanded,
                  limits: limits, pageSize: pageSize, includeAddRows: includeAddRows, rows: &rows)
        }

        if limit < count {
            rows.append(JSONTreeRow(kind: .more(shown: limit, remaining: count - limit), path: path, depth: depth + 1, label: nil))
        }

        if includeAddRows {
            rows.append(JSONTreeRow(kind: .add(kind), path: path, depth: depth + 1, label: nil))
        }

        rows.append(JSONTreeRow(kind: .closing(kind), path: path, depth: depth, label: nil))
    }
}

/// JSON literal helpers for display and inline editing.
public enum JSONLiteral {
    /// JSON text of a scalar (`"a\"b"`, `12`, `true`, `null`). Containers print compactly.
    public static func format(_ value: JSONValue) -> String {
        switch value {
        case .string(let string): return quote(string)
        case .number(let number): return number
        case .bool(let bool): return bool ? "true" : "false"
        case .null: return "null"
        case .object(let members):
            return "{" + members.map { quote($0.key) + ":" + format($0.value) }.joined(separator: ",") + "}"
        case .array(let items):
            return "[" + items.map(format).joined(separator: ",") + "]"
        }
    }

    /// Indented JSON text (2 spaces by default); big numbers are kept verbatim.
    public static func pretty(_ value: JSONValue, indent: Int = 2) -> String {
        var output = ""
        write(value, level: 0, indent: indent, into: &output)
        return output
    }

    private static func write(_ value: JSONValue, level: Int, indent: Int, into output: inout String) {
        let pad = String(repeating: " ", count: indent * (level + 1))
        let closePad = String(repeating: " ", count: indent * level)
        switch value {
        case .object(let members):
            guard !members.isEmpty else { output += "{}"; return }
            output += "{\n"
            for (index, member) in members.enumerated() {
                output += pad + quote(member.key) + ": "
                write(member.value, level: level + 1, indent: indent, into: &output)
                output += index == members.count - 1 ? "\n" : ",\n"
            }

            output += closePad + "}"
        case .array(let items):
            guard !items.isEmpty else { output += "[]"; return }
            output += "[\n"
            for (index, item) in items.enumerated() {
                output += pad
                write(item, level: level + 1, indent: indent, into: &output)
                output += index == items.count - 1 ? "\n" : ",\n"
            }

            output += closePad + "]"
        default:
            output += format(value)
        }
    }

    public static func quote(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }

        return result + "\""
    }

    /// Collapsed preview of a container, e.g. `{…}` / `[…]`, or `{}` / `[]` when empty.
    public static func collapsedPreview(_ kind: JSONContainerKind, count: Int) -> String {
        count == 0 ? kind.open + kind.close : kind.open + "…" + kind.close
    }

    /// Parses JSON text with the shared big-int-safe parser; nil when invalid.
    public static func parse(_ text: String) -> JSONValue? {
        try? JSONParser.parse(text)
    }

    /// Requires a quoted JSON string (`"name"`) and returns the unquoted key.
    public static func parseQuotedKey(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return nil }
        if case .string(let key)? = parse(trimmed) { return key }
        let inner = String(trimmed.dropFirst().dropLast())
        guard !inner.contains("\"") || inner.contains("\\\"") else { return nil }
        return inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}

/// Node paths of a row list in display order, with a path-to-position map.
public struct JSONTreeNodePaths: Sendable {
    public let paths: [JSONPath]
    public let positions: [JSONPath: Int]

    public init(rows: [JSONTreeRow]) {
        paths = rows.compactMap { row in
            switch row.kind {
            case .container, .scalar: return row.path
            default: return nil
            }
        }
        positions = Dictionary(paths.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// Document, expansion, paging and selection state for a JSON tree.
/// Keep one model per key to preserve expanded paths across refreshes.
@MainActor @Observable
public final class JSONTreeModel {
    public private(set) var root: JSONTreeNode { didSet { invalidateRows() } }
    public var expanded: Set<JSONPath> { didSet { invalidateRows() } }
    public var limits: [JSONPath: Int] = [:] { didSet { invalidateRows() } }
    public var loading: Set<JSONPath> = []
    public var errors: [JSONPath: String] = [:]
    public var selectedPath: JSONPath?
    public var pageSize: Int { didSet { invalidateRows() } }
    @ObservationIgnored private var cachedRows: [Bool: [JSONTreeRow]] = [:]
    @ObservationIgnored private var cachedNodePaths: JSONTreeNodePaths?

    public init(root: JSONTreeNode, expandRoot: Bool = true, pageSize: Int = JSONTreeFlattener.defaultPageSize) {
        self.root = root
        self.expanded = expandRoot ? [.root] : []
        self.pageSize = pageSize
    }

    public convenience init(value: JSONValue, expandRoot: Bool = true) {
        self.init(root: .value(value), expandRoot: expandRoot)
    }

    /// Replaces the document; expanded paths are kept unless `resetExpansion`.
    public func setRoot(_ node: JSONTreeNode, resetExpansion: Bool = false) {
        root = node
        errors = [:]
        if resetExpansion {
            expanded = [.root]
            limits = [:]
            selectedPath = nil
        }
    }

    public func setValue(_ value: JSONValue, resetExpansion: Bool = false) {
        setRoot(.value(value), resetExpansion: resetExpansion)
    }

    /// Visible rows, flattened once per change of the document, expansion, limits or page size.
    public func rows(includeAddRows: Bool) -> [JSONTreeRow] {
        let (root, expanded, limits, pageSize) = (root, expanded, limits, pageSize)
        if let cached = cachedRows[includeAddRows] { return cached }
        let rows = JSONTreeFlattener.rows(for: root, expanded: expanded, limits: limits, pageSize: pageSize,
                                          includeAddRows: includeAddRows)
        cachedRows[includeAddRows] = rows
        return rows
    }

    /// Selectable node paths of the visible rows in display order, with each path's position.
    public func nodePaths() -> JSONTreeNodePaths {
        let rows = rows(includeAddRows: false)
        if let cachedNodePaths { return cachedNodePaths }
        let paths = JSONTreeNodePaths(rows: rows)
        cachedNodePaths = paths
        return paths
    }

    private func invalidateRows() {
        cachedRows.removeAll()
        cachedNodePaths = nil
    }

    public func isExpanded(_ path: JSONPath) -> Bool { expanded.contains(path) }

    public func setExpanded(_ path: JSONPath, _ isExpanded: Bool) {
        if isExpanded {
            expanded.insert(path)
        } else {
            expanded.remove(path)
        }
    }

    /// Expands every loaded container down to `maxDepth` levels.
    public func expandAll(maxDepth: Int = 8) {
        var paths: Set<JSONPath> = []

        func walk(_ node: JSONTreeNode, _ path: JSONPath) {
            guard node.isContainer, node.isLoaded, path.depth <= maxDepth else { return }
            paths.insert(path)
            for (component, child) in node.children(in: 0..<min(node.childCount, limits[path] ?? pageSize)) {
                walk(child, path.appending(component))
            }
        }

        walk(root, .root)
        expanded = paths
    }

    public func collapseAll() {
        expanded = [.root]
    }

    public func showMore(at path: JSONPath) {
        limits[path] = visibleChildLimit(at: path) + pageSize
    }

    /// How many children of the container at `path` the tree shows before a "Show more" row.
    public func visibleChildLimit(at path: JSONPath) -> Int {
        limits[path] ?? pageSize
    }

    /// Replaces the children starting at `start` of the loaded container at `path` (paged fetches).
    public func replaceChildren(at path: JSONPath, from start: Int, with nodes: [JSONTreeNode]) {
        guard let node = node(at: path), start >= 0, start + nodes.count <= node.childCount else { return }
        let updated: JSONTreeNode
        switch node.expandedOneLevel {
        case .object(var members):
            for (offset, child) in nodes.enumerated() { members[start + offset].node = child }
            updated = JSONTreeNode.object(members).collapsedIfLoaded
        case .array(var items):
            items.replaceSubrange(start..<(start + nodes.count), with: nodes)
            updated = JSONTreeNode.array(items).collapsedIfLoaded
        default:
            return
        }

        replaceNode(at: path, with: updated)
    }

    public func node(at path: JSONPath) -> JSONTreeNode? { root.node(at: path) }

    public func replaceNode(at path: JSONPath, with node: JSONTreeNode) {
        if let updated = root.replacing(at: path, with: node) { root = updated }
    }

    public func removeNode(at path: JSONPath) {
        guard let updated = root.removing(at: path) else { return }
        root = updated
        expanded = expanded.filter { !$0.isDescendant(ofOrEqualTo: path) }
        if let selectedPath, selectedPath.isDescendant(ofOrEqualTo: path) { self.selectedPath = nil }
    }

    public func addNode(_ node: JSONTreeNode, key: String?, under parent: JSONPath) {
        if let updated = root.adding(node, key: key, under: parent) { root = updated }
    }
}
