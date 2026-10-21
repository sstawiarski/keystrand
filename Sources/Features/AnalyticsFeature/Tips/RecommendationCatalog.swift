import Foundation
import RedisCore

public enum RecommendationBadge: String, Sendable, Hashable, CaseIterable {
    case codeChanges = "code_changes"
    case configurationChanges = "configuration_changes"
    case upgrade

    public var label: String {
        switch self {
        case .codeChanges: return "Code Changes"
        case .configurationChanges: return "Configuration Changes"
        case .upgrade: return "Upgrade"
        }
    }

    public var systemImage: String {
        switch self {
        case .codeChanges: return "chevron.left.forwardslash.chevron.right"
        case .configurationChanges: return "gearshape"
        case .upgrade: return "arrow.up.circle"
        }
    }
}

/// One node of a tip's rich content (`recommendations.json`).
public indirect enum RecommendationNode: Sendable, Hashable {
    case paragraph(String)
    case span(String)
    case code(String)
    case codeLink(href: String, name: String)
    case link(href: String, name: String)
    case spacer(String)
    case list([[RecommendationNode]])
    case unknown(String?)

    public var isInline: Bool {
        switch self {
        case .span, .code, .codeLink, .link: return true
        default: return false
        }
    }
}

public struct RecommendationContent: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var liveTitle: String?
    public var badges: [RecommendationBadge]
    public var deprecated: Bool
    public var content: [RecommendationNode]
}

/// Bundled tip texts keyed by recommendation name.
public struct RecommendationCatalog: Sendable {
    public let items: [String: RecommendationContent]

    public static let shared: RecommendationCatalog = {
        guard let data = bundledData, let catalog = try? RecommendationCatalog(data: data) else {
            return RecommendationCatalog(items: [:])
        }
        return catalog
    }()

    static var bundledData: Data? {
        Bundle.module.url(forResource: "recommendations", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
    }

    public init(items: [String: RecommendationContent]) {
        self.items = items
    }

    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        var items: [String: RecommendationContent] = [:]
        for (name, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            let title = (entry["title"] as? String) ?? name
            let badges = (entry["badges"] as? [String] ?? []).compactMap(RecommendationBadge.init(rawValue:))
            let nodes = Self.parseNodes(entry["content"])
            items[name] = RecommendationContent(id: name, title: title, liveTitle: entry["liveTitle"] as? String, badges: badges,
                                                deprecated: entry["deprecated"] as? Bool ?? false, content: nodes)
        }

        self.items = items
    }

    public var knownNames: Set<String> { Set(items.keys) }

    public subscript(name: String) -> RecommendationContent? { items[name] }

    public func title(for name: String) -> String {
        items[name]?.title ?? name
    }

    static func parseNodes(_ value: Any?) -> [RecommendationNode] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { parseNode($0) }
    }

    static func parseNode(_ raw: Any) -> RecommendationNode? {
        guard let node = raw as? [String: Any], let type = node["type"] as? String else { return nil }
        let value = node["value"]
        let parameter = node["parameter"] as? [String]
        func text() -> String { substitute(value as? String ?? "", parameter: parameter) }

        func linkParts() -> (String, String)? {
            guard let dict = value as? [String: Any], let href = dict["href"] as? String else { return nil }
            return (href, (dict["name"] as? String) ?? href)
        }

        switch type {
        case "paragraph": return .paragraph(text())
        case "span": return .span(text())
        case "code": return .code(text())
        case "code-link": return linkParts().map { .codeLink(href: $0.0, name: $0.1) }
        case "link": return linkParts().map { .link(href: $0.0, name: $0.1) }
        case "spacer": return .spacer(value as? String ?? "s")
        case "list":
            let items = (value as? [Any] ?? []).map { parseNodes($0) }
            return .list(items)
        case "internal-link", "link-sso", "connect-btn":
            return nil
        default:
            return .unknown(value as? String)
        }
    }

    /// `${0}` placeholders are filled at render time from the tip's params; keep the marker names here.
    static func substitute(_ text: String, parameter: [String]?) -> String {
        guard let parameter, !parameter.isEmpty else { return text }
        var out = text
        for (index, name) in parameter.enumerated() {
            out = out.replacingOccurrences(of: "${\(index)}", with: "${param:\(name)}")
        }

        return out
    }

    /// Replaces `${param:keys}` markers with the first key of `params`.
    public static func fill(_ text: String, params: RecommendationParams?) -> String {
        guard text.contains("${param:") else { return text }
        let key = params?.keys.first.map(AnalyticsFormat.keyName) ?? ""
        return text.replacingOccurrences(of: "${param:keys}", with: key)
    }
}
