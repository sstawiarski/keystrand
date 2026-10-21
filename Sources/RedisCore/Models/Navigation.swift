import Foundation

/// Sections of the per-database window rail (⌘1...⌘5 in this order).
public enum DatabaseSection: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case browser
    case workbench
    case analytics
    case pubSub
    case vectorSearch

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .browser: return "Browser"
        case .workbench: return "Workbench"
        case .analytics: return "Analytics"
        case .pubSub: return "Pub/Sub"
        case .vectorSearch: return "Vector Search"
        }
    }

    public var systemImage: String {
        switch self {
        case .browser: return "key"
        case .workbench: return "terminal"
        case .analytics: return "chart.bar"
        case .pubSub: return "dot.radiowaves.left.and.right"
        case .vectorSearch: return "magnifyingglass"
        }
    }
}

public enum AnalyticsTab: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case databaseAnalysis
    case slowLog
    case clusterDetails

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .databaseAnalysis: return "Database Analysis"
        case .slowLog: return "Slow Log"
        case .clusterDetails: return "Cluster Details"
        }
    }
}

public enum BottomPanelTool: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case cli
    case commandHelper
    case profiler

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cli: return "CLI"
        case .commandHelper: return "Command Helper"
        case .profiler: return "Profiler"
        }
    }
}

public enum InsightsTab: String, CaseIterable, Codable, Sendable, Hashable {
    case tutorials
    case tips
}

public enum SampleDatasetID: String, Codable, Sendable, Hashable, CaseIterable {
    case trails = "trail-guides"
    case recipes = "recipe-ideas"
}

public enum CreateIndexRequest: Hashable, Sendable {
    case sampleData(SampleDatasetID)
    case existingData(initialKey: Data?, keyType: SearchIndexKeyType?, prefix: String?)
}

/// Requests navigation within one database window. The destination consumes each pending payload.
public enum DatabaseNavigationRequest: Hashable, Sendable {
    case section(DatabaseSection)
    case analytics(AnalyticsTab)
    /// Shows keys in the Browser.
    case browser(BrowserNavigationRequest)
    /// Opens the Browser in RediSearch mode for an index.
    case browseIndex(indexName: Data)
    /// Opens the Vector Search query page.
    case vectorSearchQuery(indexName: Data, openIndexPanel: Bool)
    /// Opens the Vector Search create-index page.
    case vectorSearchCreateIndex(CreateIndexRequest)
    /// Open Workbench, optionally putting a script into the editor.
    case workbench(script: String?)
    case pubSub
    /// Show a bottom panel tool (CLI, Command Helper, Profiler).
    case bottomPanel(BottomPanelTool)
    /// Insights > Tutorials (nil = list).
    case tutorial(id: String?)
    /// Bring the Home window forward.
    case home
    /// Open the edit-database sheet (production prompt focuses the Environment field).
    case editDatabase(focusEnvironment: Bool)

    /// Section that shows this request, if any.
    public var section: DatabaseSection? {
        switch self {
        case .section(let s): return s
        case .analytics: return .analytics
        case .browser, .browseIndex: return .browser
        case .vectorSearchQuery, .vectorSearchCreateIndex: return .vectorSearch
        case .workbench: return .workbench
        case .pubSub: return .pubSub
        case .bottomPanel, .tutorial, .home, .editDatabase: return nil
        }
    }
}
