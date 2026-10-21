import Foundation
import RedisCore

/// Home table columns (ids persisted in `settings.ui.homeShownColumns`; they double as `customizationID`s).
public enum HomeColumn: String, CaseIterable, Identifiable, Sendable {
    case name
    case host
    case connectionType
    case environment
    case modules
    case lastConnection
    case tags

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .name: return "Name"
        case .host: return "Host:Port"
        case .connectionType: return "Type"
        case .environment: return "Environment"
        case .modules: return "Modules"
        case .lastConnection: return "Last Connection"
        case .tags: return "Tags"
        }
    }
}

/// Sortable Home table fields. Fields that `HomeSorting` knows are persisted; Environment sorts for this window only.
public enum HomeSortField: String, CaseIterable, Hashable, Sendable {
    case name
    case host
    case connectionType
    case environment
    case lastConnection
    case tags

    public init(_ field: HomeSorting.Field) {
        switch field {
        case .name: self = .name
        case .host: self = .host
        case .connectionType: self = .connectionType
        case .lastConnection: self = .lastConnection
        case .tags: self = .tags
        }
    }

    public var persisted: HomeSorting.Field? {
        switch self {
        case .name: return .name
        case .host: return .host
        case .connectionType: return .connectionType
        case .environment: return nil
        case .lastConnection: return .lastConnection
        case .tags: return .tags
        }
    }
}

/// One row of the Home sidebar.
public enum HomeFilter: Hashable, Sendable {
    case all
    case recents
    case production
    case development
    case tag(DatabaseTag)

    public var isTag: Bool {
        if case .tag = self { return true }
        return false
    }

    public var title: String {
        switch self {
        case .all: return "All Databases"
        case .recents: return "Recents"
        case .production: return "Production"
        case .development: return "Development"
        case .tag(let tag): return "\(tag.key): \(tag.value)"
        }
    }

    public var systemImage: String {
        switch self {
        case .all: return "cylinder.split.1x2"
        case .recents: return "clock"
        case .production: return "exclamationmark.shield"
        case .development: return "hammer"
        case .tag: return "tag"
        }
    }
}

/// Pure formatting / filtering / sorting rules of the Home database list.
public enum DatabaseListLogic {
    /// `name` (first 200 chars) plus ` [dbN]` when a logical database is selected.
    public static func displayName(_ config: DatabaseConfig, limit: Int = 200) -> String {
        let name = String(config.name.prefix(limit))
        return config.dbIndex > 0 ? "\(name) [db\(config.dbIndex)]" : name
    }

    public static func fullDisplayName(_ config: DatabaseConfig) -> String {
        config.dbIndex > 0 ? "\(config.name) [db\(config.dbIndex)]" : config.name
    }

    public static func connectionTypeLabel(_ type: ConnectionType) -> String {
        type == .notConnected ? "Not Connected" : type.displayName
    }

    /// "Production", "Development", or nil for an unspecified environment.
    public static func environmentLabel(_ environment: DatabaseEnvironment) -> String? {
        switch environment {
        case .production: return "Production"
        case .development: return "Development"
        case .unspecified: return nil
        }
    }

    /// Detected hosting provider for display; nil when not detected or unknown.
    public static func providerLabel(_ provider: HostingProvider?) -> String? {
        switch provider {
        case nil, .unknown?: return nil
        case .localhost?: return "Localhost"
        case .redisCloud?: return "Redis Cloud"
        case .redisSoftware?: return "Redis Software"
        case .redisCommunityEdition?: return "Redis Community Edition"
        case .redisStack?: return "Redis Stack"
        case .awsElastiCache?: return "AWS ElastiCache"
        case .awsMemoryDB?: return "AWS MemoryDB"
        case .azureCache?: return "Azure Cache for Redis"
        case .azureCacheRedisEnterprise?: return "Azure Cache for Redis Enterprise"
        case .googleMemorystore?: return "Google Memorystore"
        case .upstash?: return "Upstash"
        case .keyDB?: return "KeyDB"
        case .dragonfly?: return "Dragonfly"
        case .valkey?: return "Valkey"
        }
    }

    /// Name used in confirmations: max 50 chars, keeps the last 10.
    public static func confirmationName(_ name: String) -> String {
        TextTruncation.formatLongName(name, maxLength: 50, tail: 10)
    }

    public static func tagText(_ tag: DatabaseTag) -> String {
        "\(tag.key):\(tag.value)"
    }

    // MARK: - Relative time

    /// Formats relative connection times, such as "5 minutes ago" or "Never".
    public static func lastConnectionText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Never" }
        return relativeDistance(from: date, to: now) + " ago"
    }

    static func relativeDistance(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int((seconds / 60).rounded())
        if seconds < 30 { return "less than a minute" }
        if minutes < 2 { return "1 minute" }
        if minutes < 45 { return "\(minutes) minutes" }
        if minutes < 90 { return "about 1 hour" }
        let hours = Int((Double(minutes) / 60).rounded())
        if minutes < 1440 { return "about \(hours) hours" }
        if minutes < 2520 { return "1 day" }
        let days = Int((Double(minutes) / 1440).rounded())
        if minutes < 43_200 { return "\(days) days" }
        if minutes < 86_400 { return "about 1 month" }
        let months = Int((Double(minutes) / 43_200).rounded())
        if minutes < 525_600 { return "\(max(2, months)) months" }
        let years = minutes / 525_600
        let remainder = minutes % 525_600
        if remainder < 131_400 { return years == 1 ? "about 1 year" : "about \(years) years" }
        if remainder < 394_200 { return years == 1 ? "over 1 year" : "over \(years) years" }
        return "almost \(years + 1) years"
    }

    // MARK: - Modules

    private static let moduleOrder = ["Redis Search", "JSON", "Graph", "Time Series", "Probabilistic", "Gears", "AI",
                                      "Vector Set"]

    /// Modules in display order (known first, unknown after in original order).
    public static func orderedModules(_ modules: [RedisModuleInfo]) -> [RedisModuleInfo] {
        modules.enumerated().sorted { lhs, rhs in
            let l = moduleOrder.firstIndex(of: lhs.element.displayName) ?? Int.max
            let r = moduleOrder.firstIndex(of: rhs.element.displayName) ?? Int.max
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
    }

    public static func moduleTooltip(_ modules: [RedisModuleInfo]) -> String {
        orderedModules(modules).map { module in
            module.versionText.map { "\(module.displayName) v. \($0)" } ?? module.displayName
        }.joined(separator: "\n")
    }

    // MARK: - Search and filters

    /// Case-insensitive substring match over every visible column.
    public static func matches(_ config: DatabaseConfig, query: String, now: Date = Date()) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        let haystacks = [
            config.name,
            config.host,
            String(config.port),
            config.hostPort,
            connectionTypeLabel(config.connectionType),
            environmentLabel(config.environment) ?? "",
            orderedModules(config.modules).map(\.displayName).joined(separator: ","),
            lastConnectionText(config.lastConnection, now: now),
        ] + config.tags.map(tagText) + config.tags.map { "\($0.key): \($0.value)" }
        return haystacks.contains { $0.lowercased().contains(needle) }
    }

    /// Visible when the database has ANY of the selected tags (empty filter shows all).
    public static func matches(_ config: DatabaseConfig, tagFilter: Set<DatabaseTag>) -> Bool {
        tagFilter.isEmpty || config.tags.contains(where: tagFilter.contains)
    }

    public static func filter(_ databases: [DatabaseConfig], query: String, tagFilter: Set<DatabaseTag>,
                              now: Date = Date()) -> [DatabaseConfig] {
        databases.filter { matches($0, tagFilter: tagFilter) && matches($0, query: query, now: now) }
    }

    public static let recentsLimit = 10

    /// The 10 most recently connected databases.
    public static func recents(_ databases: [DatabaseConfig]) -> Set<DatabaseID> {
        let connected = databases.compactMap { config in config.lastConnection.map { (config.id, $0) } }
        return Set(connected.sorted { $0.1 > $1.1 }.prefix(recentsLimit).map(\.0))
    }

    /// Sidebar filter match. Library and environment rows are exclusive; tag rows match ANY selected tag.
    public static func matches(_ config: DatabaseConfig, filters: Set<HomeFilter>, recents: Set<DatabaseID>) -> Bool {
        let tags = Set(filters.compactMap { filter -> DatabaseTag? in
            if case .tag(let tag) = filter { return tag }
            return nil
        })
        if !tags.isEmpty { return config.tags.contains(where: tags.contains) }
        if filters.contains(.recents) { return recents.contains(config.id) }
        if filters.contains(.production) { return config.environment == .production }
        if filters.contains(.development) { return config.environment == .development }
        return true
    }

    /// Number of databases a sidebar row matches.
    public static func count(for filter: HomeFilter, in databases: [DatabaseConfig], recents: Set<DatabaseID>) -> Int {
        databases.filter { matches($0, filters: [filter], recents: recents) }.count
    }

    /// Applies the sidebar selection rules to a proposed `List` selection: a newly selected Library or Environment
    /// row replaces everything; tag rows combine with each other only; an empty selection means All Databases.
    public static func resolveFilters(previous: Set<HomeFilter>, proposed: Set<HomeFilter>) -> Set<HomeFilter> {
        let added = proposed.subtracting(previous)
        if let exclusive = added.first(where: { !$0.isTag }) { return [exclusive] }
        let tags = proposed.filter(\.isTag)
        if !tags.isEmpty { return tags }
        if let exclusive = proposed.first { return [exclusive] }
        return [.all]
    }

    /// True when the sidebar selection narrows the list.
    public static func isFiltering(_ filters: Set<HomeFilter>) -> Bool {
        !(filters.isEmpty || filters == [.all])
    }

    /// Distinct tags across databases, sorted by key then value.
    public static func allTags(_ databases: [DatabaseConfig]) -> [DatabaseTag] {
        var seen = Set<DatabaseTag>()
        return databases.flatMap(\.tags).filter { seen.insert($0).inserted }
            .sorted { ($0.key, $0.value) < ($1.key, $1.value) }
    }

    /// Window subtitle: "12 databases", "3 of 12 databases" when narrowed, "2 selected" for a multi-selection.
    public static func subtitle(total: Int, visible: Int, selected: Int, isNarrowed: Bool) -> String {
        if selected > 1 { return "\(selected) selected" }
        let noun = total == 1 ? "database" : "databases"
        if isNarrowed { return "\(visible) of \(total) \(noun)" }
        return "\(total) \(noun)"
    }

    // MARK: - Sorting

    /// `lastConnection` "asc" lists the most recent first; never-connected last.
    public static func sort(_ databases: [DatabaseConfig], by sorting: HomeSorting) -> [DatabaseConfig] {
        databases.sorted { areInIncreasingOrder($0, $1, sorting: sorting) }
    }

    public static func sort(_ databases: [DatabaseConfig], field: HomeSortField, ascending: Bool) -> [DatabaseConfig] {
        databases.sorted { areInIncreasingOrder($0, $1, field: field, ascending: ascending) }
    }

    public static func areInIncreasingOrder(_ lhs: DatabaseConfig, _ rhs: DatabaseConfig, sorting: HomeSorting) -> Bool {
        areInIncreasingOrder(lhs, rhs, field: HomeSortField(sorting.field), ascending: sorting.direction == .asc)
    }

    public static func areInIncreasingOrder(_ lhs: DatabaseConfig, _ rhs: DatabaseConfig, field: HomeSortField,
                                            ascending: Bool) -> Bool {
        switch field {
        case .lastConnection:
            switch (lhs.lastConnection, rhs.lastConnection) {
            case (nil, nil): return tieBreak(lhs, rhs)
            case (nil, _): return false
            case (_, nil): return true
            case let (l?, r?):
                if l == r { return tieBreak(lhs, rhs) }
                return ascending ? l > r : l < r
            }
        case .environment:
            let l = environmentRank(lhs.environment)
            let r = environmentRank(rhs.environment)
            if l == r { return tieBreak(lhs, rhs) }
            return ascending ? l < r : l > r
        default:
            let l = sortKey(lhs, field: field)
            let r = sortKey(rhs, field: field)
            let result = l.localizedStandardCompare(r)
            if result == .orderedSame { return tieBreak(lhs, rhs) }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func environmentRank(_ environment: DatabaseEnvironment) -> Int {
        switch environment {
        case .production: return 0
        case .development: return 1
        case .unspecified: return 2
        }
    }

    static func sortKey(_ config: DatabaseConfig, field: HomeSortField) -> String {
        switch field {
        case .name: return config.name.lowercased()
        case .host: return "\(config.host.lowercased()):\(config.port)"
        case .connectionType: return config.connectionType.rawValue
        case .tags: return config.tags.first.map { tagText($0).lowercased() } ?? ""
        case .lastConnection, .environment: return ""
        }
    }

    private static func tieBreak(_ lhs: DatabaseConfig, _ rhs: DatabaseConfig) -> Bool {
        lhs.id.rawValue < rhs.id.rawValue
    }

    // MARK: - Columns

    /// Shown columns from the persisted ids (empty = all). Name is always shown.
    public static func shownColumns(from ids: [String]) -> Set<HomeColumn> {
        let parsed = Set(ids.compactMap(HomeColumn.init(rawValue:)))
        return parsed.isEmpty ? Set(HomeColumn.allCases) : parsed.union([.name])
    }

    public static func persistedColumns(_ columns: Set<HomeColumn>) -> [String] {
        let shown = columns.union([.name])
        return shown.count == HomeColumn.allCases.count ? [] : HomeColumn.allCases.filter(shown.contains).map(\.rawValue)
    }

    // MARK: - Confirmations and toasts

    /// `Remove “name”?` for one database, `Remove 3 Databases?` for several.
    public static func removalTitle(names: [String]) -> String {
        if names.count == 1, let name = names.first { return "Remove “\(confirmationName(name))”?" }
        return "Remove \(names.count) Databases?"
    }

    /// Removal message; several databases list up to 10 names first.
    public static func removalMessage(names: [String]) -> String {
        let note = "Your data on the server is not affected."
        guard names.count > 1 else { return "The connection will be removed from Keystrand. \(note)" }
        let listed = names.prefix(10).map { TextTruncation.formatLongName($0, maxLength: 60, tail: 10) }
        let more = names.count > 10 ? ", and \(names.count - 10) more" : ""
        return "The connections to \(listed.joined(separator: ", "))\(more) will be removed from Keystrand. \(note)"
    }

    /// `Keystrand_connections_<epochMillis>.json`
    public static func exportFileName(now: Date = Date()) -> String {
        "Keystrand_connections_\(Int64(now.timeIntervalSince1970 * 1000)).json"
    }
}
