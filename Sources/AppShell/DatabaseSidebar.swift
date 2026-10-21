import AnalyticsFeature
import MonitoringFeature
import RedisUI
import SwiftUI

enum DatabaseSidebarItem: String, CaseIterable, Identifiable, Hashable, Sendable {
    case browser
    case workbench
    case vectorSearch
    case databaseAnalysis
    case slowLog
    case clusterDetails
    case pubSub

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case data = "Data"
        case analytics = "Analytics"
        case messaging = "Messaging"
        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .browser, .workbench, .vectorSearch: return .data
        case .databaseAnalysis, .slowLog, .clusterDetails: return .analytics
        case .pubSub: return .messaging
        }
    }

    var title: String {
        switch self {
        case .browser: return "Browser"
        case .workbench: return "Workbench"
        case .vectorSearch: return "Vector Search"
        case .databaseAnalysis: return "Database Analysis"
        case .slowLog: return "Slow Log"
        case .clusterDetails: return "Cluster Details"
        case .pubSub: return "Pub/Sub"
        }
    }

    var systemImage: String {
        switch self {
        case .browser: return "key"
        case .workbench: return "chevron.left.forwardslash.chevron.right"
        case .vectorSearch: return "sparkle.magnifyingglass"
        case .databaseAnalysis: return "chart.pie"
        case .slowLog: return "tortoise"
        case .clusterDetails: return "server.rack"
        case .pubSub: return "dot.radiowaves.left.and.right"
        }
    }

    /// ⌘1 … ⌘7 in sidebar order.
    var shortcutKey: KeyEquivalent {
        KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1)))
    }

    var section: DatabaseSection {
        switch self {
        case .browser: return .browser
        case .workbench: return .workbench
        case .vectorSearch: return .vectorSearch
        case .databaseAnalysis, .slowLog, .clusterDetails: return .analytics
        case .pubSub: return .pubSub
        }
    }

    var analyticsTab: AnalyticsTab? {
        switch self {
        case .databaseAnalysis: return .databaseAnalysis
        case .slowLog: return .slowLog
        case .clusterDetails: return .clusterDetails
        default: return nil
        }
    }

    init(section: DatabaseSection, analyticsTab: AnalyticsTab) {
        switch section {
        case .browser: self = .browser
        case .workbench: self = .workbench
        case .vectorSearch: self = .vectorSearch
        case .pubSub: self = .pubSub
        case .analytics:
            switch analyticsTab {
            case .databaseAnalysis: self = .databaseAnalysis
            case .slowLog: self = .slowLog
            case .clusterDetails: self = .clusterDetails
            }
        }
    }

    /// Values of the `--section` launch flag.
    init?(flag: String) {
        switch flag.lowercased() {
        case "browser": self = .browser
        case "workbench": self = .workbench
        case "vectorsearch", "vector-search", "search": self = .vectorSearch
        case "analysis", "analytics": self = .databaseAnalysis
        case "slowlog", "slow-log": self = .slowLog
        case "cluster": self = .clusterDetails
        case "pubsub", "pub-sub": self = .pubSub
        default: return nil
        }
    }

    /// Cluster Details is available only for clusters.
    func resolved(isCluster: Bool) -> DatabaseSidebarItem {
        self == .clusterDetails && !isCluster ? .databaseAnalysis : self
    }

    static func visibleItems(isCluster: Bool) -> [DatabaseSidebarItem] {
        allCases.filter { $0 != .clusterDetails || isCluster }
    }

    @MainActor
    static func current(_ navigator: DatabaseNavigator) -> DatabaseSidebarItem {
        DatabaseSidebarItem(section: navigator.section, analyticsTab: navigator.analyticsTab)
    }

    @MainActor
    func apply(to navigator: DatabaseNavigator) {
        if let analyticsTab, navigator.analyticsTab != analyticsTab { navigator.analyticsTab = analyticsTab }
        if navigator.section != section { navigator.section = section }
    }
}

enum DatabaseWindowTitle {
    static func title(name: String, dbIndex: Int) -> String {
        var title = String(name.prefix(33))
        if dbIndex > 0 { title += " [db\(dbIndex)]" }
        return title
    }

    static func subtitle(item: DatabaseSidebarItem, host: String, port: Int) -> String {
        "\(item.title) · \(host):\(port)"
    }

    @MainActor
    static func title(session: DatabaseSession) -> String {
        title(name: session.config.name, dbIndex: session.effectiveDB)
    }

    @MainActor
    static func subtitle(session: DatabaseSession) -> String {
        subtitle(item: .current(session.navigator), host: session.config.host, port: session.config.port)
    }
}

struct DatabaseSidebar: View {
    let session: DatabaseSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let items = DatabaseSidebarItem.visibleItems(isCluster: session.isCluster)
        List(selection: selection) {
            ForEach(DatabaseSidebarItem.Group.allCases) { group in
                Section(group.rawValue) {
                    ForEach(items.filter { $0.group == group }) { item in
                        row(item).tag(item)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var selection: Binding<DatabaseSidebarItem?> {
        Binding(
            get: { DatabaseSidebarItem.current(session.navigator) },
            set: { item in
                guard let item else { return }
                item.resolved(isCluster: session.isCluster).apply(to: session.navigator)
            }
        )
    }

    @ViewBuilder
    private func row(_ item: DatabaseSidebarItem) -> some View {
        switch item {
        case .databaseAnalysis:
            Label(item.title, systemImage: item.systemImage)
                .badge(LiveTipsModel.shared(for: session).totalUnread)
        case .pubSub:
            Label {
                Text(item.title)
            } icon: {
                Image(systemName: item.systemImage)
                    .symbolEffect(.variableColor.iterative,
                                  isActive: PubSubView.isSubscribed(session: session) && !reduceMotion)
            }
        default:
            Label(item.title, systemImage: item.systemImage)
        }
    }
}
