import Foundation
import RedisCore

public enum KeyTreeNodeID: Hashable, Sendable {
    /// Folder path: segments joined by `KeyTreeBuilder.pathSeparator`.
    case folder(String)
    case leaf(Data)
}

/// Immutable node of the Browser tree view. Built off the main actor by `KeyTreeBuilder`.
public final class KeyTreeNode: Identifiable, Sendable {
    public let id: KeyTreeNodeID
    /// Folder segment, or the last segment of a key name.
    public let name: String
    /// Folder: segments joined by the delimiter (`a:b`); leaf: the whole display name.
    public let fullName: String
    /// Original key bytes (leaves only).
    public let keyName: Data?
    /// False when the key (or any key below the folder) is not valid printable UTF-8.
    public let isPrintable: Bool
    public let children: [KeyTreeNode]
    /// Keys under the folder (1 for a leaf).
    public let keyCount: Int
    /// Share of all loaded keys, 0...100.
    public let percentage: Double

    init(id: KeyTreeNodeID, name: String, fullName: String, keyName: Data?, isPrintable: Bool,
         children: [KeyTreeNode], keyCount: Int, percentage: Double) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.keyName = keyName
        self.isPrintable = isPrintable
        self.children = children
        self.keyCount = keyCount
        self.percentage = percentage
    }

    public var isLeaf: Bool { keyName != nil }

    public var folderPath: String? {
        if case .folder(let path) = id { return path }
        return nil
    }
}

/// One visible row of the flattened tree.
public struct KeyTreeRow: Identifiable, Sendable {
    public let node: KeyTreeNode
    public let depth: Int
    public let isExpanded: Bool
    public var id: KeyTreeNodeID { node.id }
}

public struct KeyTreeOptions: Hashable, Sendable {
    public var delimiters: [String]
    public var prefixLength: Int
    public var sort: RedisCore.SortOrder

    public init(delimiters: [String] = [":"], prefixLength: Int = 0, sort: RedisCore.SortOrder = .asc) {
        self.delimiters = delimiters
        self.prefixLength = prefixLength
        self.sort = sort
    }

    /// Delimiter shown between folder segments (`-` when several delimiters are configured).
    public var delimiterView: String { delimiters.count == 1 ? delimiters[0] : "-" }
}

public struct KeyTreeInput: Sendable {
    public var name: Data
    public var display: String
    public var isPrintable: Bool

    public init(name: Data, display: String, isPrintable: Bool = true) {
        self.name = name
        self.display = display
        self.isPrintable = isPrintable
    }
}

/// Builds a key tree without I/O.
public enum KeyTreeBuilder {
    public static let pathSeparator = "\u{1F}"
    /// Maximum delimiter-prefix length offered in tree settings.
    public static let maxPrefixLength = 512
    /// Deepest folder level. Segments past it stay in the leaf name, so building, flattening, and freeing the tree
    /// never recurse deeper than this, whatever the key names look like.
    public static let maxFolderDepth = 128

    // MARK: - Splitting

    /// Splits on the first matching delimiter at each position, excluding the first `prefixLength` UTF-16 units
    /// and the first `{...}` hash tag.
    public static func split(_ name: String, delimiters: [String], prefixLength: Int) -> [String] {
        let delims = delimiters.filter { !$0.isEmpty }.map { Array($0.utf16) }
        let units = Array(name.utf16)
        guard !delims.isEmpty else { return name.map { String($0) } }
        let pLength = max(prefixLength, 0)

        let tagStart = units.firstIndex(of: 0x7B) ?? -1
        var tagEnd = -1
        if tagStart >= 0, tagStart + 1 <= units.count {
            tagEnd = units[(tagStart + 1)...].firstIndex(of: 0x7D) ?? -1
        }

        let hasHashTag = tagStart >= 0 && tagEnd > tagStart + 1

        if !hasHashTag {
            if pLength == 0 { return splitAll(units, from: 0, delims: delims) }
            let cut = min(pLength, units.count)
            let prefix = string(units, 0, cut)
            var rest = splitAll(units, from: cut, delims: delims)
            if rest.isEmpty { rest = [""] }
            return [prefix + rest[0]] + rest.dropFirst()
        }

        var parts: [String] = []
        var partStart = 0
        var searchFrom = pLength
        while let (index, length) = nextMatch(units, from: searchFrom, delims: delims) {
            if index >= pLength && (index <= tagStart || index + length > tagEnd) {
                parts.append(string(units, partStart, index))
                partStart = index + length
                searchFrom = index + length
            } else {
                searchFrom = index + 1
            }
        }

        parts.append(string(units, partStart, units.count))
        return parts
    }

    private static func splitAll(_ units: [UInt16], from start: Int, delims: [[UInt16]]) -> [String] {
        var parts: [String] = []
        var partStart = start
        var searchFrom = start
        while let (index, length) = nextMatch(units, from: searchFrom, delims: delims) {
            parts.append(string(units, partStart, index))
            partStart = index + length
            searchFrom = index + length
        }

        parts.append(string(units, partStart, units.count))
        return parts
    }

    private static func nextMatch(_ units: [UInt16], from start: Int, delims: [[UInt16]]) -> (Int, Int)? {
        guard start < units.count else { return nil }
        var i = max(start, 0)
        while i < units.count {
            for delim in delims where i + delim.count <= units.count {
                var matches = true
                for (offset, unit) in delim.enumerated() where units[i + offset] != unit {
                    matches = false
                    break
                }

                if matches { return (i, delim.count) }
            }

            i += 1
        }

        return nil
    }

    private static func string(_ units: [UInt16], _ start: Int, _ end: Int) -> String {
        guard start < end, start >= 0, end <= units.count else { return "" }
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    /// `split` with every segment past `maxFolderDepth` joined back into the last part.
    public static func segments(_ name: String, options: KeyTreeOptions) -> [String] {
        let parts = split(name, delimiters: options.delimiters, prefixLength: options.prefixLength)
        guard parts.count > maxFolderDepth + 1 else { return parts }
        return Array(parts[..<maxFolderDepth]) + [parts[maxFolderDepth...].joined(separator: options.delimiterView)]
    }

    // MARK: - Building

    private final class Folder {
        var folders: [String: Folder] = [:]
        var leaves: [(input: KeyTreeInput, short: String)] = []
    }

    /// Builds the sorted tree: folders before keys, each group sorted by name (ASC/DESC, English collation).
    public static func build(_ keys: [KeyTreeInput], options: KeyTreeOptions) -> [KeyTreeNode] {
        let root = Folder()
        for key in keys {
            let parts = segments(key.display, options: options)
            var current = root
            for segment in parts.dropLast() {
                if let next = current.folders[segment] {
                    current = next
                } else {
                    let next = Folder()
                    current.folders[segment] = next
                    current = next
                }
            }

            current.leaves.append((key, parts.last ?? key.display))
        }

        let total = max(keys.count, 1)
        return makeChildren(root, parentPath: nil, parentFullName: nil, total: total, options: options)
    }

    private static func makeChildren(_ folder: Folder, parentPath: String?, parentFullName: String?, total: Int,
                                     options: KeyTreeOptions) -> [KeyTreeNode] {
        let ascending = options.sort == .asc
        let folderNames = folder.folders.keys.sorted { ordered($0, $1, ascending: ascending) }
        var nodes: [KeyTreeNode] = []
        nodes.reserveCapacity(folderNames.count + folder.leaves.count)
        for segment in folderNames {
            guard let child = folder.folders[segment] else { continue }
            let path = parentPath.map { $0 + pathSeparator + segment } ?? segment
            let fullName = parentFullName.map { $0 + options.delimiterView + segment } ?? segment
            let children = makeChildren(child, parentPath: path, parentFullName: fullName, total: total, options: options)
            let count = children.reduce(0) { $0 + $1.keyCount }
            let printable = children.allSatisfy(\.isPrintable)
            nodes.append(KeyTreeNode(id: .folder(path), name: segment, fullName: fullName, keyName: nil,
                                     isPrintable: printable, children: children, keyCount: count,
                                     percentage: Double(count) / Double(total) * 100))
        }

        let leaves = folder.leaves.sorted { ordered($0.input.display, $1.input.display, ascending: ascending) }
        for leaf in leaves {
            nodes.append(KeyTreeNode(id: .leaf(leaf.input.name), name: leaf.short, fullName: leaf.input.display,
                                     keyName: leaf.input.name, isPrintable: leaf.input.isPrintable, children: [],
                                     keyCount: 1, percentage: 100 / Double(total)))
        }

        return nodes
    }

    private static let collationLocale = Locale(identifier: "en")

    static func ordered(_ a: String, _ b: String, ascending: Bool) -> Bool {
        let result = a.compare(b, options: [], range: nil, locale: collationLocale)
        if result == .orderedSame { return ascending ? a < b : a > b }
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }

    // MARK: - Visible rows

    /// Depth-first rows for the expanded folders.
    public static func flatten(_ roots: [KeyTreeNode], expanded: Set<String>) -> [KeyTreeRow] {
        var rows: [KeyTreeRow] = []

        func visit(_ nodes: [KeyTreeNode], depth: Int) {
            for node in nodes {
                let isExpanded = node.folderPath.map { expanded.contains($0) } ?? false
                rows.append(KeyTreeRow(node: node, depth: depth, isExpanded: isExpanded))
                if isExpanded { visit(node.children, depth: depth + 1) }
            }
        }

        visit(roots, depth: 0)
        return rows
    }

    /// `node` plus each descendant folder that is the only child of its parent (auto-expanded together).
    public static func singleChildChain(from node: KeyTreeNode) -> [String] {
        var paths: [String] = []
        var current: KeyTreeNode? = node
        while let folder = current, let path = folder.folderPath {
            paths.append(path)
            if folder.children.count == 1, let only = folder.children.first, !only.isLeaf {
                current = only
            } else {
                current = nil
            }
        }

        return paths
    }

    /// Folder paths that contain the key with display name `display` (outermost first).
    public static func parentFolderPaths(of display: String, options: KeyTreeOptions) -> [String] {
        let parts = segments(display, options: options)
        var paths: [String] = []
        var current: String?
        for segment in parts.dropLast() {
            let path = current.map { $0 + pathSeparator + segment } ?? segment
            paths.append(path)
            current = path
        }

        return paths
    }

    /// Finds a node by id (depth-first).
    public static func find(_ id: KeyTreeNodeID, in nodes: [KeyTreeNode]) -> KeyTreeNode? {
        for node in nodes {
            if node.id == id { return node }
            if case .folder(let target) = id, let path = node.folderPath, !target.hasPrefix(path) { continue }
            if let found = find(id, in: node.children) { return found }
        }

        return nil
    }
}
