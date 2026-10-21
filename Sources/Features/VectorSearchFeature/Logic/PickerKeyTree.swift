import Foundation
import RedisUI

/// Tree settings of the create-index keys browser, persisted with the Browser's per-database tree settings.
struct PickerTreeOptions: Hashable, Sendable {
    static let maxPrefixLength = 512

    var delimiters: [String] = [":"]
    var prefixLength = 0
    var sort: RedisCore.SortOrder = .asc

    init(delimiters: [String] = [":"], prefixLength: Int = 0, sort: RedisCore.SortOrder = .asc) {
        let cleaned = delimiters.filter { !$0.isEmpty }
        self.delimiters = cleaned.isEmpty ? [":"] : cleaned
        self.prefixLength = min(max(prefixLength, 0), Self.maxPrefixLength)
        self.sort = sort
    }

    init(_ settings: DatabaseSettings) {
        self.init(delimiters: settings.treeViewDelimiters, prefixLength: settings.treeViewDelimiterPrefixLength,
                  sort: settings.treeViewSort)
    }

    var delimiterView: String { delimiters.count == 1 ? delimiters[0] : "-" }
}

/// A folder of keys with a shared delimited prefix, or a single key.
final class PickerTreeNode: Identifiable, Sendable {
    enum ID: Hashable, Sendable {
        case folder(String)
        case leaf(Data)
    }

    let id: ID
    let name: String
    let keyName: Data?
    let children: [PickerTreeNode]
    let keyCount: Int

    init(id: ID, name: String, keyName: Data?, children: [PickerTreeNode], keyCount: Int) {
        self.id = id
        self.name = name
        self.keyName = keyName
        self.children = children
        self.keyCount = keyCount
    }

    var folderPath: String? {
        if case .folder(let path) = id { return path }
        return nil
    }
}

struct PickerTreeRow: Identifiable, Sendable {
    let node: PickerTreeNode
    let depth: Int
    let isExpanded: Bool
    var id: PickerTreeNode.ID { node.id }
}

/// Builds a tree with folders before keys, sorting both by name.
enum PickerKeyTree {
    static let pathSeparator = "\u{1F}"
    static let maxFolderDepth = 64

    /// Splits on any delimiter, ignoring split points inside the first `prefixLength` characters.
    static func split(_ name: String, options: PickerTreeOptions) -> [String] {
        let chars = Array(name)
        let delims = options.delimiters.map(Array.init)
        var parts: [String] = []
        var start = 0
        var i = min(options.prefixLength, chars.count)
        while i < chars.count {
            if let delim = delims.first(where: { i + $0.count <= chars.count && chars[i..<(i + $0.count)].elementsEqual($0) }) {
                parts.append(String(chars[start..<i]))
                i += delim.count
                start = i
                if parts.count == maxFolderDepth { break }
            } else {
                i += 1
            }
        }

        parts.append(String(chars[start...]))
        return parts
    }

    private final class Folder {
        var folders: [String: Folder] = [:]
        var leaves: [(name: Data, short: String)] = []
    }

    static func build(_ keys: [(name: Data, display: String)], options: PickerTreeOptions) -> [PickerTreeNode] {
        let root = Folder()
        for key in keys {
            let parts = split(key.display, options: options)
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

            current.leaves.append((key.name, parts.last ?? key.display))
        }

        return children(of: root, path: nil, options: options)
    }

    private static func children(of folder: Folder, path: String?, options: PickerTreeOptions) -> [PickerTreeNode] {
        let ascending = options.sort == .asc
        let order: (String, String) -> Bool = { a, b in
            let result = a.localizedStandardCompare(b)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        let folders = folder.folders.keys.sorted(by: order).compactMap { segment -> PickerTreeNode? in
            guard let child = folder.folders[segment] else { return nil }
            let childPath = path.map { $0 + pathSeparator + segment } ?? segment
            let nodes = children(of: child, path: childPath, options: options)
            let count = nodes.reduce(0) { $0 + $1.keyCount }
            return PickerTreeNode(id: .folder(childPath), name: segment, keyName: nil, children: nodes, keyCount: count)
        }
        let leaves = folder.leaves.sorted { order($0.short, $1.short) }.map {
            PickerTreeNode(id: .leaf($0.name), name: $0.short, keyName: $0.name, children: [], keyCount: 1)
        }
        return folders + leaves
    }

    static func flatten(_ roots: [PickerTreeNode], expanded: Set<String>) -> [PickerTreeRow] {
        var rows: [PickerTreeRow] = []

        func visit(_ nodes: [PickerTreeNode], depth: Int) {
            for node in nodes {
                let isOpen = node.folderPath.map { expanded.contains($0) } ?? false
                rows.append(PickerTreeRow(node: node, depth: depth, isExpanded: isOpen))
                if isOpen { visit(node.children, depth: depth + 1) }
            }
        }

        visit(roots, depth: 0)
        return rows
    }
}
