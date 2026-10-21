import ConnectionsFeature
import Foundation
import RedisUI

/// Keeps a deep link’s `redirect` page until its database window opens.
enum DeepLink {
    static let scheme = DatabaseDeepLink.scheme

    /// `redirect` page paths (`workbench`, `analytics/slowlog`, `browser?tutorialId=…`) as window navigation.
    static func redirect(_ text: String) -> DatabaseNavigationRequest? {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let components = URLComponents(string: trimmed) else { return nil }
        if let tutorial = components.queryItems?.first(where: { $0.name == "tutorialId" || $0.name == "guidePath" }) {
            return .tutorial(id: tutorial.value)
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        switch path {
        case "browser", "_": return .section(.browser)
        case "workbench": return .workbench(script: nil)
        case "analytics", "analytics/database-analysis": return .analytics(.databaseAnalysis)
        case "analytics/slowlog": return .analytics(.slowLog)
        case "analytics/cluster-details": return .analytics(.clusterDetails)
        case "pub-sub", "pubsub": return .pubSub
        case "vector-search", "search": return .section(.vectorSearch)
        default: return nil
        }
    }
}

/// Navigation for a database window opened by a deep link, consumed when the window appears.
@MainActor
enum DeepLinkRedirects {
    private static var pending: [DatabaseID: DatabaseNavigationRequest] = [:]
    private static var awaiting: (link: DatabaseDeepLink, request: DatabaseNavigationRequest)?

    static func set(_ request: DatabaseNavigationRequest?, for id: DatabaseID) {
        pending[id] = request
    }

    static func consume(_ id: DatabaseID) -> DatabaseNavigationRequest? {
        pending.removeValue(forKey: id)
    }

    /// Keeps the link’s redirect until the matching database opens.
    static func expect(_ link: DatabaseDeepLink) {
        awaiting = link.redirect.flatMap(DeepLink.redirect).map { (link, $0) }
    }

    /// Drops the link's redirect after the user declines to connect.
    static func cancel(_ link: DatabaseDeepLink) {
        if awaiting?.link == link { awaiting = nil }
    }

    /// Attaches the pending redirect if this is the linked database.
    static func databaseOpened(_ config: DatabaseConfig) {
        guard let awaiting, awaiting.link.matchingDatabase(in: [config]) != nil else { return }
        pending[config.id] = awaiting.request
        self.awaiting = nil
    }
}
