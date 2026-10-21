import Foundation
import RedisCore

/// One node of the bundled tutorials `manifest.json` (a group or an internal link to a markdown page).
public struct TutorialNode: Decodable, Identifiable, Hashable, Sendable {
    public struct Args: Decodable, Hashable, Sendable {
        public var path: String?
        public var initialIsOpen: Bool?
        public var withBorder: Bool?
    }

    public var id: String
    public var type: String
    public var label: String
    public var summary: String?
    public var args: Args?
    public var children: [TutorialNode]?

    public var isGroup: Bool { type == "group" }
    public var isPage: Bool { type == "internal-link" && args?.path != nil }
}

public enum TutorialError: Error, LocalizedError, Equatable {
    case missingResources
    case notFound(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .missingResources: return "The bundled tutorials could not be found."
        case .notFound(let id): return "The tutorial \"\(id)\" does not exist."
        case .unreadable(let path): return "The tutorial file \(path) could not be read."
        }
    }
}

/// A match of the tutorials search.
public struct TutorialSearchHit: Identifiable, Hashable, Sendable {
    public var node: TutorialNode
    /// Labels of the enclosing groups, outermost first (root excluded).
    public var groupPath: [String]
    /// Text around the match in the page body (nil when the label or summary matched).
    public var excerpt: String?
    public var id: String { node.id }
}

/// The bundled tutorials tree and page lookup. Pure and Sendable, so loading and searching run off the main actor.
public struct TutorialLibrary: Sendable {
    public let root: TutorialNode
    public let baseURL: URL
    private let parents: [String: String]

    public init(root: TutorialNode, baseURL: URL) {
        self.root = root
        self.baseURL = baseURL
        var parents: [String: String] = [:]

        func walk(_ node: TutorialNode) {
            for child in node.children ?? [] {
                parents[child.id] = node.id
                walk(child)
            }
        }

        walk(root)
        self.parents = parents
    }

    /// Loads `Tutorials/manifest.json` from the target bundle.
    public static func bundled() throws -> TutorialLibrary {
        guard let base = Bundle.module.url(forResource: "Tutorials", withExtension: nil) else {
            throw TutorialError.missingResources
        }
        return try load(from: base)
    }

    public static func load(from base: URL) throws -> TutorialLibrary {
        let manifestURL = base.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw TutorialError.unreadable("manifest.json") }
        let root = try JSONDecoder().decode(TutorialNode.self, from: data)
        return TutorialLibrary(root: root, baseURL: base)
    }

    public func node(id: String) -> TutorialNode? {
        func find(_ node: TutorialNode) -> TutorialNode? {
            if node.id == id { return node }
            for child in node.children ?? [] {
                if let hit = find(child) { return hit }
            }

            return nil
        }

        return find(root)
    }

    public func parent(of id: String) -> TutorialNode? {
        parents[id].flatMap { node(id: $0) }
    }

    /// Enclosing group labels, outermost first, without the root.
    public func groupPath(of id: String) -> [String] {
        var path: [String] = []
        var current = parents[id]
        while let groupID = current, groupID != root.id, let group = node(id: groupID) {
            path.insert(group.label, at: 0)
            current = parents[groupID]
        }

        return path
    }

    /// Page siblings (internal links of the same group) in manifest order.
    public func siblings(of id: String) -> [TutorialNode] {
        guard let parent = parent(of: id) else { return node(id: id).map { [$0] } ?? [] }
        return (parent.children ?? []).filter(\.isPage)
    }

    public var allPages: [TutorialNode] {
        var out: [TutorialNode] = []

        func walk(_ node: TutorialNode) {
            if node.isPage { out.append(node) }
            for child in node.children ?? [] { walk(child) }
        }

        walk(root)
        return out
    }

    public func fileURL(for node: TutorialNode) -> URL? {
        guard let path = node.args?.path else { return nil }
        return baseURL.appendingPathComponent(Self.relativePath(path))
    }

    public func markdown(for node: TutorialNode) throws -> String {
        guard let url = fileURL(for: node) else { throw TutorialError.notFound(node.id) }
        guard let data = try? Data(contentsOf: url) else { throw TutorialError.unreadable(node.args?.path ?? node.id) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Case-insensitive search over labels, summaries and (when given) page bodies keyed by node id.
    public func search(_ query: String, contents: [String: String] = [:]) -> [TutorialSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var hits: [TutorialSearchHit] = []
        for page in allPages {
            let path = groupPath(of: page.id)
            if page.label.range(of: needle, options: .caseInsensitive) != nil
                || page.summary?.range(of: needle, options: .caseInsensitive) != nil
                || path.contains(where: { $0.range(of: needle, options: .caseInsensitive) != nil }) {
                hits.append(TutorialSearchHit(node: page, groupPath: path, excerpt: nil))
            } else if let body = contents[page.id], let range = body.range(of: needle, options: .caseInsensitive) {
                hits.append(TutorialSearchHit(node: page, groupPath: path, excerpt: Self.excerpt(body, around: range)))
            }
        }

        return hits
    }

    static func excerpt(_ text: String, around range: Range<String.Index>, radius: Int = 50) -> String {
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end].replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "`", with: "")
        return (start > text.startIndex ? "…" : "") + body.trimmingCharacters(in: .whitespaces)
            + (end < text.endIndex ? "…" : "")
    }

    /// The page a relative Markdown link on `page` points to (`hashes.md`, `../sq/indexing.md`), or nil.
    public func page(linkedFrom url: URL, on page: TutorialNode) -> TutorialNode? {
        guard url.scheme == nil, !url.relativePath.isEmpty, let current = page.args?.path,
              let base = URL(string: "file:///" + Self.relativePath(current)),
              let target = URL(string: url.relativePath, relativeTo: base)?.absoluteURL.standardized else { return nil }
        let path = Self.relativePath(target.path)
        return allPages.first { $0.args?.path.map(Self.relativePath) == path }
    }

    private static func relativePath(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    /// Capitalizes the first letter of every word.
    public static func startCase(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// A ```` ```redis:[params] Label ```` fence of a tutorial page.
public struct TutorialFence: Hashable, Sendable {
    public static let maxLabelLength = 86

    public var label: String
    public var params: ExecuteParams?

    public var runConfirmation: Bool { params?.runConfirmation ?? false }
    public var isExecutable: Bool { params?.executable ?? true }

    /// Nil when the fence is not a `redis` block.
    public static func parse(info: String) -> TutorialFence? {
        let trimmed = info.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("redis") else { return nil }
        var rest = Substring(trimmed.dropFirst("redis".count))
        if let first = rest.first, first != ":", first != " " { return nil }
        var params: ExecuteParams?
        if rest.hasPrefix(":") {
            rest = rest.dropFirst()
            if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                params = WorkbenchScriptParser.parseParams(String(rest[...close]))
                rest = rest[rest.index(after: close)...]
            }
        }

        return TutorialFence(label: rest.trimmingCharacters(in: .whitespaces), params: params)
    }

    public var displayLabel: String {
        label.count > Self.maxLabelLength ? String(label.prefix(Self.maxLabelLength)) + "…" : label
    }

    /// Execution params for the Workbench run (fence params; the editor is never touched).
    public var executeParams: ExecuteParams {
        var out = params ?? ExecuteParams()
        out.clearEditor = false
        return out
    }
}
